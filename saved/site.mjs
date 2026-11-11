// Royal Saved: the website's storage, Apple sign-in and sync, without the page.
// The CloudKit client, library and sync rules are the extension's own modules
// (shared/, copied byte for byte), so saves merge exactly as they do there. This
// site only ever reads and writes saved posts: seen and All records are filtered
// out before they reach the library, so it can never push them.
import { CloudKitClient, CloudKitError, ROYAL_CLOUDKIT, appleSignInURL, callbackToken, describeCloudKitError } from "./shared/cloudkit.mjs";
import { accountLibraryKey, createLibrary, LIBRARY_KEY, SYNC_SETTINGS_KEY } from "./shared/store.mjs";
import { startSync } from "./shared/sync.mjs";
import { runSync, SyncPausedError } from "./shared/sync-runner.mjs";

// Royal's container in Production, with the website's own web API token. In
// CloudKit Console the token's sign-in callback is a URL Redirect to
// https://royal.tinyk.ing/ and its allowed origin is royal.tinyk.ing only.
// A web API token identifies the app, not a user, and is meant to be public.
export const SITE_CLOUDKIT = Object.freeze({
  ...ROYAL_CLOUDKIT,
  apiToken: "984378b0e9f112a1fff7bac52fab23c69e168e4687138d2289b5139bb5f0aa10",
});

export const TOKEN_KEY = "royalCloudKitToken";
// Set in sessionStorage when this tab sends someone to Apple's sign-in, so a
// token in the address is only accepted on the way back from a sign-in started
// here (a link carrying someone else's token can't sign this browser in to the
// wrong account).
export const SIGN_IN_STARTED_KEY = "royalSignInStarted";
const SIGN_IN_WINDOW = 15 * 60 * 1000;
const SIGN_IN_CODES = ["AUTHENTICATION_REQUIRED", "AUTHENTICATION_FAILED"];

// chrome.storage.local's get/set/remove over Web Storage, for the shared library.
export function webStore(storage) {
  return {
    async get(key) {
      const raw = storage.getItem(key);
      if (raw == null) return { [key]: undefined };
      try { return { [key]: JSON.parse(raw) }; } catch { return { [key]: undefined }; }
    },
    async set(entries) { for (const [key, value] of Object.entries(entries)) storage.setItem(key, JSON.stringify(value)); },
    async remove(key) { storage.removeItem(key); },
  };
}

const isSavedRecord = record => typeof record?.recordName === "string" && record.recordName.startsWith("saved.");

// The CloudKit client as the sync runner uses it, seeing only saved-post records.
export function savedOnly(api) {
  return {
    config: api.config,
    currentUser: () => api.currentUser(),
    ensureSyncZone: () => api.ensureSyncZone(),
    async zoneChanges(syncToken) {
      const changes = await api.zoneChanges(syncToken);
      return { ...changes, records: changes.records.filter(isSavedRecord) };
    },
    modifySyncRecords: operations => api.modifySyncRecords(operations),
  };
}

// Reads the CloudKit token Apple appended to this page's address. Returns null
// when there is none; otherwise the address without Apple's parameters (to put
// back in the address bar straight away) and the token, or `refused` when this
// tab didn't start a sign-in in the last 15 minutes.
export function takeCallback(href, { pending, now = Date.now() }) {
  const url = new URL(href);
  const names = [...url.searchParams.keys()].filter(name => name.startsWith("ck"));
  if (names.length === 0) return null;
  for (const name of names) url.searchParams.delete(name);
  const started = Number(pending.getItem(SIGN_IN_STARTED_KEY));
  pending.removeItem(SIGN_IN_STARTED_KEY);
  const cleanURL = url.href;
  if (!(started > 0 && now - started >= 0 && now - started < SIGN_IN_WINDOW)) return { cleanURL, token: null, refused: true };
  try {
    return { cleanURL, token: callbackToken(href, new URL("/", href).href), refused: false };
  } catch {
    return { cleanURL, token: null, refused: true };
  }
}

export function syncMessage(error) {
  if (error instanceof SyncPausedError) return `Sync paused: ${error.message}`;
  if (error instanceof CloudKitError && SIGN_IN_CODES.includes(error.code)) return "Sign in again to keep syncing. Changes stay pending.";
  if (error instanceof CloudKitError) return `Sync failed: ${describeCloudKitError(error)} Changes stay pending.`;
  return "Sync failed. Changes stay pending.";
}

// `storage`: Web Storage for the library and token (localStorage).
// `pending`: Web Storage for the sign-in marker (sessionStorage).
// `locks`: navigator.locks, so tabs take turns with the library and CloudKit.
export function createSite({ storage, pending, locks, fetcher, config = SITE_CLOUDKIT, now = () => Date.now() }) {
  const store = webStore(storage);
  let onLocalChange = () => {};
  const library = createLibrary({
    storage: store, now,
    fetchFeed: async () => { throw new Error("Royal Saved doesn't fetch feeds."); },
    onChange: () => onLocalChange(),
  });
  const getToken = async () => (await store.get(TOKEN_KEY))[TOKEN_KEY] ?? null;
  const setToken = token => (token ? store.set({ [TOKEN_KEY]: token }) : store.remove(TOKEN_KEY));
  const client = () => new CloudKitClient(config, { fetcher, getToken, setToken });
  const exclusive = task => (locks ? locks.request("royal-saved", () => task()) : task());

  const view = async () => ({ ...(await library.view()), signedIn: Boolean(await getToken()) });

  // Makes the signed-in Apple Account's library the active one.
  async function useAccount(api) {
    const account = await api.currentUser();
    await library.useSync({ account, container: api.config.container, environment: api.config.environment }, startSync);
  }

  async function syncNow() {
    let message, signInNeeded = false, ok = false;
    try {
      const api = savedOnly(client());
      if (!(await getToken())) throw new CloudKitError("AUTHENTICATION_REQUIRED");
      if (!(await library.settings())) await useAccount(api);
      const result = await runSync({ api, library, now });
      ok = true;
      message = result.failed ? `${result.failed} change${result.failed === 1 ? " was" : "s were"} refused; ${result.pending} pending.` : null;
    } catch (error) {
      signInNeeded = error instanceof CloudKitError && SIGN_IN_CODES.includes(error.code);
      message = syncMessage(error);
    }
    return { ...(await view()), ok, message, signInNeeded };
  }

  return {
    set onLocalChange(callback) { onLocalChange = callback; },
    view: () => exclusive(view),
    setSaved: (post, saved) => exclusive(async () => { await library.setSaved(post, saved); return view(); }),
    sync: () => exclusive(syncNow),

    // Returns Apple's sign-in address to go to. Throws when CloudKit refuses for
    // another reason (such as a token not set up for this site).
    beginSignIn: () => exclusive(async () => {
      await setToken(null);
      try {
        await client().currentUser();
      } catch (error) {
        if (!(error instanceof CloudKitError) || error.code !== "AUTHENTICATION_REQUIRED" || !error.redirectURL) throw error;
        const url = appleSignInURL(error.redirectURL);
        pending.setItem(SIGN_IN_STARTED_KEY, String(now()));
        return url;
      }
      throw new Error("CloudKit didn't ask for a sign-in.");
    }),

    // With the token from takeCallback: signs in and syncs.
    finishSignIn: token => exclusive(async () => {
      await setToken(token);
      return syncNow();
    }),

    // Forgets the token and this browser's copy of the account's saved posts;
    // they stay in iCloud. Pending changes that haven't synced are lost, so the
    // page asks first.
    signOut: () => exclusive(async () => {
      const settings = await library.settings();
      await setToken(null);
      await library.useSync(null);
      if (settings) await store.remove(accountLibraryKey(settings));
      await store.remove(LIBRARY_KEY);
      await store.remove(SYNC_SETTINGS_KEY);
      return view();
    }),
  };
}

export { CloudKitError, describeCloudKitError };
