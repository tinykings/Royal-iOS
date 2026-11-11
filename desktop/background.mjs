import { fetchFeed } from "./feeds.mjs";
import { createLibrary } from "./store.mjs";
import { startSync } from "./sync.mjs";
import { runSync, SyncPausedError } from "./sync-runner.mjs";
import { CloudKitClient, CloudKitError, ROYAL_CLOUDKIT, appleSignInURL, callbackToken, describeCloudKitError } from "./cloudkit.mjs";

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

// Do not expose authentication to content scripts; the UI receives status only.
// The CloudKit web auth token is kept in local storage, as CloudKit JS keeps its
// session, so sync survives browser restarts and extension updates (session
// storage is wiped by both). Sign out removes it, and CloudKit can still expire
// it, which asks for a new sign-in.
const storageReady = Promise.all([
  chrome.storage.local.setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" }),
  chrome.storage.session.setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" }),
]).then(async () => {
  // Earlier versions kept the token in session storage.
  const { cloudKitToken } = await chrome.storage.session.get("cloudKitToken");
  if (cloudKitToken) {
    await chrome.storage.local.set({ cloudKitToken });
    await chrome.storage.session.remove("cloudKitToken");
  }
  // Before 0.6.1 the container, token, and environment were entered by hand. A
  // sign-in made with anything other than Royal's own configuration is dropped.
  const { cloudKitConfig } = await chrome.storage.local.get("cloudKitConfig");
  if (cloudKitConfig) {
    const same = ["container", "environment", "apiToken"].every(key => cloudKitConfig[key] === ROYAL_CLOUDKIT[key]);
    if (!same) await chrome.storage.local.remove("cloudKitToken");
    await chrome.storage.local.remove("cloudKitConfig");
  }
});
let queue = Promise.resolve();
async function setToken(token) {
  if (token) await chrome.storage.local.set({ cloudKitToken: token });
  else await chrome.storage.local.remove("cloudKitToken");
}

const signedIn = async () => Boolean((await chrome.storage.local.get("cloudKitToken")).cloudKitToken);

async function client() {
  return new CloudKitClient(ROYAL_CLOUDKIT, {
    getToken: async () => (await chrome.storage.local.get("cloudKitToken")).cloudKitToken,
    setToken,
  });
}

async function handle(request) {
  await storageReady;
  switch (request.action) {
    case "status":
      return { callback: chrome.identity.getRedirectURL("cloudkit"), origin: `chrome-extension://${chrome.runtime.id}` };
    case "diagnose": {
      // Intentionally invalid API token: this checks HTTP reachability without
      // sending the user's configuration or changing their sign-in session.
      const granted = await chrome.permissions.contains({ origins: ["https://api.apple-cloudkit.com/*"] });
      if (!granted) return { message: "CloudKit host access is not granted. In the browser's extension Details, allow Royal access to api.apple-cloudkit.com, then retry." };
      const api = new CloudKitClient({ ...ROYAL_CLOUDKIT, apiToken: "royal-connectivity-check-not-a-real-token" }, {
        getToken: async () => null, setToken: async () => {},
      });
      try { await api.currentUser(); }
      catch (error) {
        if (!(error instanceof CloudKitError)) throw error;
        if (error.httpStatus) return { message: `Connection check: CloudKit returned HTTP ${error.httpStatus} (${error.code}) to an intentionally invalid test token. HTTP reachability works. If Sign in still fails, inspect that request in the service worker; check the real token's environment and allowed origin. This check does not verify your token or Apple login.` };
        return { message: `Connection check: host permission is granted, but the browser delivered no HTTP response. ${describeCloudKitError(error)} No real API token was used.` };
      }
      return { message: "Connection check reached CloudKit. This does not verify Royal's token or your Apple login." };
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
      // Being signed in is what turns sync on.
      await useAccount(api);
      return syncNow(api);
    }
    case "signOut":
      // Turns sync off. The account's copy (with anything still pending) stays in
      // this browser for the next sign-in to the same account; another account
      // never sees it.
      await setToken(null);
      return { ...(await library.useSync(null)), message: "Signed out. Sync is off and Royal shows this browser's own library. Your Apple login in the browser is unchanged." };
    case "sync": {
      const api = await client();
      if (!(await library.settings())) {
        if (!(await api.getToken())) return { ...(await library.view()), message: "Not signed in. Royal keeps everything in this browser." };
        // Signed in before sign-in turned sync on (0.6.1 and earlier).
        await useAccount(api);
      }
      return syncNow(api);
    }
    default: throw new Error("Unknown Royal operation.");
  }
}

// Syncs the signed-in Apple Account's library, creating it from this browser's
// own library (an import that never overwrites synced records) the first time.
async function useAccount(api) {
  const account = await api.currentUser();
  const { container, environment } = api.config;
  await library.useSync({ account, container, environment }, startSync);
}

const SIGN_IN_CODES = ["AUTHENTICATION_REQUIRED", "AUTHENTICATION_FAILED"];

async function syncNow(api, { notify = false } = {}) {
  syncTimer = clearTimeout(syncTimer);
  let message, signInNeeded = false;
  try {
    // Without an iCloud sign-in, CloudKit can only refuse; say so instead.
    if ((await library.settings()) && !(await api.getToken())) {
      throw new CloudKitError("AUTHENTICATION_REQUIRED");
    }
    const result = await runSync({ api, library });
    message = `Synced. Received ${result.pulled}, sent ${result.pushed}${result.failed ? `, ${result.failed} refused` : ""}; ${result.pending} pending.`;
    console.info(`[Royal sync] ${message}`);
  } catch (error) {
    signInNeeded = error instanceof CloudKitError && SIGN_IN_CODES.includes(error.code);
    message = error instanceof SyncPausedError ? `Sync paused: ${error.message}`
      : signInNeeded ? "Sync paused: sign in to iCloud again. Changes stay pending."
      : error instanceof CloudKitError ? `Sync failed: ${describeCloudKitError(error)} Changes stay pending.`
        : "Sync failed. Changes stay pending.";
    console.warn(`[Royal sync] ${error instanceof CloudKitError ? `${error.code}${error.httpStatus ? ` HTTP ${error.httpStatus}` : ""}${error.operation ? ` ${error.operation}` : ""}` : error?.message}`);
  }
  const view = await library.view();
  // After a background sync, let an open Royal page redraw with what arrived.
  // (A page that asked for this sync gets the result as its reply.)
  if (notify) chrome.runtime.sendMessage({ event: "libraryChanged" }).catch(() => {});
  return { ...view, message, syncMessage: message, signInNeeded };
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

// With sync on, Refresh All first pulls what other devices have seen, through the
// CloudKit queue, so posts already shown on iOS land under Earlier instead of New
// even when this page has been open since before they were seen. A failed sync
// (offline, signed out) doesn't stop the refresh; its message is shown instead.
async function refreshAllAfterSync() {
  let synced = null;
  if (await library.settings()) {
    const operation = queue.then(async () => { await storageReady; return syncNow(await client()); });
    queue = operation.catch(() => {});
    synced = await operation.catch(() => null);
  }
  const view = await library.refreshAll();
  return synced ? { ...view, syncMessage: synced.syncMessage, signInNeeded: synced.signInNeeded } : view;
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
    refreshAll: () => refreshAllAfterSync(),
    markAllRead: () => library.markAllRead(),
    setSaved: () => library.setSaved(request.post, request.saved),
  };
  const libraryOperation = Object.hasOwn(libraryOperations, request?.action) ? libraryOperations[request.action] : null;
  if (libraryOperation) {
    storageReady.then(libraryOperation)
      .then(async result => respond({ ok: true, ...result, signedIn: await signedIn() }), error => {
        console.warn(`[Royal feeds] ${request.action}: ${error?.message}`);
        respond({ ok: false, message: /^(Unknown feed|Invalid )/.test(error?.message ?? "") ? error.message : "Feed request failed." });
      });
    return true;
  }
  const operation = queue.then(() => handle(request));
  queue = operation.catch(() => {});
  operation.then(async result => respond({ ok: true, ...result, signedIn: await signedIn() }), error => {
    // Browser identity errors can include the redirect URL. Never echo them.
    const message = error instanceof CloudKitError
      ? describeCloudKitError(error)
      : /^Sync |^Unknown Royal|^Configuration|^CloudKit returned|^Apple sign-in/.test(error.message ?? "")
        ? error.message : "Operation failed. Check Apple sign-in, callback configuration, and connectivity.";
    respond({ ok: false, message });
  });
  return true;
});
