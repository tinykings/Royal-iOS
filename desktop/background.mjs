import { CloudKitClient, CloudKitError, appleSignInURL, callbackToken, validateConfig } from "./cloudkit.mjs";

const pageURL = chrome.runtime.getURL("index.html");
chrome.action.onClicked.addListener(() => { chrome.tabs.create({ url: pageURL }); });

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
    case "configure": {
      const config = validateConfig(request.config);
      await setToken(null);
      await chrome.storage.local.set({ cloudKitConfig: config });
      return { message: "Configuration saved. Sign in with Apple next." };
    }
    case "signIn": {
      await setToken(null);
      const api = await client();
      try { await api.currentUser(); }
      catch (error) {
        if (!(error instanceof CloudKitError) || error.code !== "AUTHENTICATION_REQUIRED" || !error.redirectURL) throw error;
        const result = await chrome.identity.launchWebAuthFlow({ url: appleSignInURL(error.redirectURL), interactive: true });
        if (!result) throw new Error("Apple sign-in was cancelled.");
        await setToken(callbackToken(result, chrome.identity.getRedirectURL("cloudkit")));
      }
      currentAccount = await api.currentUser();
      return { message: "Signed in to your private CloudKit database. Read the probe next." };
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
    default: throw new Error("Unknown Royal operation.");
  }
}

chrome.runtime.onMessage.addListener((request, sender, respond) => {
  if (sender.id !== chrome.runtime.id || sender.url !== pageURL) return false;
  const operation = queue.then(() => handle(request));
  queue = operation.catch(() => {});
  operation.then(result => respond({ ok: true, ...result }), error => {
    // Browser identity errors can include the redirect URL. Never echo them.
    const message = error instanceof CloudKitError
      ? `CloudKit: ${error.code}. Check the setup guide; conflicts require reading again.`
      : /^Enter |^Choose |^Read |^Apple Account changed|^Unknown Royal|^Configuration|^CloudKit returned|^Apple sign-in/.test(error.message ?? "")
        ? error.message : "Operation failed. Check Apple sign-in, callback configuration, and connectivity.";
    respond({ ok: false, message });
  });
  return true;
});
