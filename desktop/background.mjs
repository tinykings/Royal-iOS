import { fetchFeed } from "./feeds.mjs";
import { createLibrary } from "./store.mjs";
import { startSync } from "./sync.mjs";
import { runSync, SyncPausedError } from "./sync-runner.mjs";
import { CloudKitClient, CloudKitError, appleSignInURL, callbackToken, validateConfig, describeCloudKitError } from "./cloudkit.mjs";

const pageURL = chrome.runtime.getURL("index.html");
chrome.action.onClicked.addListener(() => { chrome.tabs.create({ url: pageURL }); });

// YouTube's embed refuses to play without a referrer (error 153), and extension
// pages send none. Like iOS's player, name Royal's site, only for embeds Royal's
// own page loads.
chrome.declarativeNetRequest?.updateSessionRules({
  removeRuleIds: [1],
  addRules: [{
    id: 1, priority: 1,
    action: { type: "modifyHeaders", requestHeaders: [{ header: "referer", operation: "set", value: "https://tinykings.github.io/" }] },
    condition: { urlFilter: "|https://www.youtube.com/embed/", resourceTypes: ["sub_frame"], initiatorDomains: [chrome.runtime.id] },
  }],
}).catch(error => console.warn(`[Royal player] Couldn't set the embed referrer: ${error?.message ?? error}`));

// Do not expose configuration or authentication to content scripts. Session tokens
// stay in the worker and expire when the browser closes; UI receives status only.
const storageReady = Promise.all([
  chrome.storage.local.setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" }),
  chrome.storage.session.setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" }),
]);
let queue = Promise.resolve();
let probe;
let hasRead = false;
let currentAccount;

function resetProbe() { probe = undefined; hasRead = false; currentAccount = undefined; }
async function setToken(token) {
  if (token) await chrome.storage.session.set({ cloudKitToken: token });
  else { await chrome.storage.session.remove("cloudKitToken"); resetProbe(); }
}

async function client() {
  const { cloudKitConfig } = await chrome.storage.local.get("cloudKitConfig");
  return new CloudKitClient(cloudKitConfig, {
    getToken: async () => (await chrome.storage.session.get("cloudKitToken")).cloudKitToken,
    setToken,
  });
}

function displayRecord(record) {
  if (!record) return null;
  return { message: record.fields?.message?.value ?? "", writtenAt: record.fields?.writtenAt?.value ?? "" };
}

async function handle(request) {
  await storageReady;
  switch (request.action) {
    case "status": {
      const { cloudKitConfig } = await chrome.storage.local.get("cloudKitConfig");
      return { config: cloudKitConfig ?? null, callback: chrome.identity.getRedirectURL("cloudkit"), origin: `chrome-extension://${chrome.runtime.id}` };
    }
    case "diagnose": {
      // Intentionally invalid API token: this checks HTTP reachability without
      // sending the user's configuration or changing their sign-in session.
      const granted = await chrome.permissions.contains({ origins: ["https://api.apple-cloudkit.com/*"] });
      if (!granted) return { message: "CloudKit host access is not granted. In the browser's extension Details, allow Royal access to api.apple-cloudkit.com, then retry." };
      const api = new CloudKitClient({ container: "iCloud.com.tinykings.Royal", environment: "production", apiToken: "royal-connectivity-check-not-a-real-token" }, {
        getToken: async () => null, setToken: async () => {},
      });
      try { await api.currentUser(); }
      catch (error) {
        if (!(error instanceof CloudKitError)) throw error;
        if (error.httpStatus) return { message: `Connection check: CloudKit returned HTTP ${error.httpStatus} (${error.code}) to an intentionally invalid test token. HTTP reachability works. If Sign in still fails, inspect that request in the service worker; check the real token's environment and allowed origin. This check does not verify your token or Apple login.` };
        return { message: `Connection check: host permission is granted, but the browser delivered no HTTP response. ${describeCloudKitError(error)} No real API token was used.` };
      }
      return { message: "Connection check reached CloudKit. This does not verify your configured token or Apple login." };
    }
    case "configure": {
      const config = validateConfig(request.config);
      await setToken(null);
      await chrome.storage.local.set({ cloudKitConfig: config });
      // Synced libraries belong to one container/environment/account.
      await library.useSync(null);
      chrome.runtime.sendMessage({ event: "libraryChanged" }).catch(() => {});
      return { message: "Configuration saved. Sign in with Apple next." };
    }
    case "signIn": {
      await setToken(null);
      const api = await client();
      try { await api.currentUser(); }
      catch (error) {
        if (!(error instanceof CloudKitError) || error.code !== "AUTHENTICATION_REQUIRED" || !error.redirectURL) throw error;
        const callback = chrome.identity.getRedirectURL("cloudkit");
        console.info(`[Royal sign-in] ${callbackHint(error.redirectURL)}`);
        let result;
        try { result = await chrome.identity.launchWebAuthFlow({ url: appleSignInURL(error.redirectURL), interactive: true }); }
        catch (flowError) {
          // The browser's own error could include an address with a token; keep
          // only its wording.
          const reason = String(flowError?.message ?? flowError).replace(/\b[a-z][\w+.-]*:\/\/\S+/gi, "[address]").slice(0, 200);
          console.warn(`[Royal sign-in] Browser web auth flow failed: ${reason}`);
          throw new Error(`Apple sign-in didn't come back to this extension (browser said: "${reason}"). If you finished logging in, check that the web API token's redirect URL in CloudKit Console is saved as exactly ${callback}, then try again.`);
        }
        if (!result) throw new Error("Apple sign-in was cancelled.");
        await setToken(callbackToken(result, chrome.identity.getRedirectURL("cloudkit")));
      }
      currentAccount = await api.currentUser();
      return { message: "Signed in to CloudKit. Read the probe next to verify private database access." };
    }
    case "signOut":
      await setToken(null);
      return { message: "Royal's local CloudKit session cleared. Your Apple browser login is unchanged.", record: null };
    case "read": {
      const api = await client();
      const account = await api.currentUser();
      if (currentAccount !== account) resetProbe();
      currentAccount = account;
      // A failed read invalidates the previous edit base.
      hasRead = false;
      probe = await api.readProbe();
      hasRead = true;
      return { record: displayRecord(probe), message: probe ? "Private probe read." : "No probe yet. Write a message to create one." };
    }
    case "write": {
      if (!hasRead) throw new Error("Read the probe before writing.");
      const api = await client();
      if (await api.currentUser() !== currentAccount) {
        resetProbe();
        throw new Error("Apple Account changed. Read the probe again.");
      }
      try { probe = await api.writeProbe(request.message, probe); }
      catch (error) { hasRead = false; throw error; }
      return { record: displayRecord(probe), message: "Private probe written. Read it from iOS to verify sync." };
    }
    case "enableSync": {
      const api = await client();
      const account = await api.currentUser();
      const { container, environment } = api.config;
      await library.useSync({ account, container, environment }, startSync);
      return syncNow(api);
    }
    case "disableSync":
      return { ...(await library.useSync(null)), message: "Sync is off. Showing this browser's local library; the synced copy and its pending changes are kept for when you turn sync on again." };
    case "sync":
      return syncNow(await client());
    default: throw new Error("Unknown Royal operation.");
  }
}

async function syncNow(api, { notify = false } = {}) {
  syncTimer = clearTimeout(syncTimer);
  let message;
  try {
    const result = await runSync({ api, library });
    message = `Synced. Received ${result.pulled}, sent ${result.pushed}${result.failed ? `, ${result.failed} refused` : ""}; ${result.pending} pending.`;
    console.info(`[Royal sync] ${message}`);
  } catch (error) {
    message = error instanceof SyncPausedError ? `Sync paused: ${error.message}`
      : error instanceof CloudKitError ? `Sync failed: ${describeCloudKitError(error)} Changes stay pending.`
        : "Sync failed. Changes stay pending.";
    console.warn(`[Royal sync] ${error instanceof CloudKitError ? `${error.code}${error.httpStatus ? ` HTTP ${error.httpStatus}` : ""}${error.operation ? ` ${error.operation}` : ""}` : error?.message}`);
  }
  const view = await library.view();
  // After a background sync, let an open Royal page redraw with what arrived.
  // (A page that asked for this sync gets the result as its reply.)
  if (notify) chrome.runtime.sendMessage({ event: "libraryChanged" }).catch(() => {});
  return { ...view, message, syncMessage: message };
}

// After a local change, sync shortly, once, through the CloudKit queue. If the
// worker stops first, the change stays pending until the next sync.
let syncTimer;
function scheduleSync() {
  clearTimeout(syncTimer);
  syncTimer = setTimeout(() => {
    syncTimer = undefined;
    queue = queue.then(async () => { await storageReady; await syncNow(await client(), { notify: true }); }).catch(() => {});
  }, 1500);
}

// Which extension callback Apple's login link names, if it names one. Only
// extension IDs are reported (they aren't secret), never the link itself.
function callbackHint(loginURL) {
  let text = String(loginURL);
  for (let i = 0; i < 3; i++) { try { text = decodeURIComponent(text); } catch { break; } }
  const ids = [...new Set([...text.matchAll(/([a-p]{32})\.chromiumapp\.org/g)].map(match => match[1]))];
  if (ids.length === 0) return "Apple's login link names no chromiumapp.org callback; it can't be checked before login.";
  const mine = ids.includes(chrome.runtime.id);
  return `Apple's login link returns to ${ids.join(", ")}; this extension is ${chrome.runtime.id}${mine ? " (match)." : ". MISMATCH: the token's redirect URL isn't in effect yet."}`;
}

const feedContext = { hasHostAccess: origin => chrome.permissions.contains({ origins: [origin] }) };
const library = createLibrary({ storage: chrome.storage.local, fetchFeed: request => fetchFeed(request, feedContext), onChange: scheduleSync });

chrome.runtime.onMessage.addListener((request, sender, respond) => {
  if (sender.id !== chrome.runtime.id || sender.url !== pageURL) return false;
  // Feed and library requests don't touch CloudKit state, so they bypass the
  // CloudKit queue. The library serializes its own storage updates.
  const libraryOperations = {
    feed: () => fetchFeed(request, feedContext),
    library: () => library.view(),
    refreshAll: () => library.refreshAll(),
    markAllRead: () => library.markAllRead(),
    setSaved: () => library.setSaved(request.post, request.saved),
  };
  const libraryOperation = Object.hasOwn(libraryOperations, request?.action) ? libraryOperations[request.action] : null;
  if (libraryOperation) {
    storageReady.then(libraryOperation)
      .then(result => respond({ ok: true, ...result }), error => {
        console.warn(`[Royal feeds] ${request.action}: ${error?.message}`);
        respond({ ok: false, message: /^(Unknown feed|Invalid )/.test(error?.message ?? "") ? error.message : "Feed request failed." });
      });
    return true;
  }
  const operation = queue.then(() => handle(request));
  queue = operation.catch(() => {});
  operation.then(result => respond({ ok: true, ...result }), error => {
    // Browser identity errors can include the redirect URL. Never echo them.
    const message = error instanceof CloudKitError
      ? describeCloudKitError(error)
      : /^Enter |^Choose |^Read |^Sync |^Apple Account changed|^Unknown Royal|^Configuration|^CloudKit returned|^Apple sign-in/.test(error.message ?? "")
        ? error.message : "Operation failed. Check Apple sign-in, callback configuration, and connectivity.";
    respond({ ok: false, message });
  });
  return true;
});
