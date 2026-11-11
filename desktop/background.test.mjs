import { test } from "node:test";
import assert from "node:assert/strict";
import { ROYAL_CLOUDKIT } from "./cloudkit.mjs";

test("worker isolates callers, serializes CloudKit use, and pauses sync without a sign-in", async () => {
  const local = {}, session = {}, listeners = [];
  const pageURL = "chrome-extension://royal-test/index.html";
  const storage = values => ({
    setAccessLevel: async () => {},
    get: async key => ({ [key]: values[key] }),
    set: async entries => Object.assign(values, entries),
    remove: async key => { delete values[key]; },
  });
  let active = 0, maximumActive = 0;
  let messageListener;
  let hostAccess = true, networkFails = false;
  globalThis.chrome = {
    runtime: { id: "royal-test", getURL: () => pageURL, sendMessage: async () => {}, onMessage: { addListener: fn => { messageListener = fn; } } },
    action: { onClicked: { addListener: fn => listeners.push(fn) } },
    tabs: { create: async () => {} },
    permissions: { contains: async () => hostAccess },
    storage: { local: storage(local), session: storage(session) },
    identity: { getRedirectURL: () => "https://royal-test.chromiumapp.org/cloudkit", launchWebAuthFlow: async () => "https://royal-test.chromiumapp.org/cloudkit?ckWebAuthToken=initial-token" },
  };
  const savedFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url, options) => {
    requests.push(`${new URL(url).host}${new URL(url).pathname}`);
    if (networkFails) throw new TypeError(`Failed to fetch ${url}`);
    active++; maximumActive = Math.max(maximumActive, active);
    await new Promise(resolve => setTimeout(resolve, 1));
    active--;
    const path = new URL(url).pathname;
    let body;
    if (path.endsWith("users/caller")) {
      assert.match(path, /\/public\/users\/caller$/);
      if (new URL(url).searchParams.get("ckAPIToken") === "royal-connectivity-check-not-a-real-token") {
        assert.equal(new URL(url).searchParams.has("ckWebAuthToken"), false);
        return { ok: false, status: 401, json: async () => ({ serverErrorCode: "AUTHENTICATION_FAILED" }) };
      }
      body = new URL(url).searchParams.has("ckWebAuthToken")
        ? { userRecordName: "account-a", ckWebAuthToken: "rotated-token" }
        : { serverErrorCode: "AUTHENTICATION_REQUIRED", redirectURL: "https://idmsa.apple.com/login" };
    } else if (path.endsWith("zones/modify")) {
      body = { zones: [{ zoneID: { zoneName: "RoyalSync" } }] };
    } else if (path.endsWith("records/changes")) {
      body = { records: [], syncToken: "sync-token" };
    } else if (path.endsWith("records/modify")) {
      assert.ok(JSON.parse(options.body).zoneID, "writes stay in the sync zone");
      body = { records: JSON.parse(options.body).operations.map(op => ({ ...op.record, recordChangeTag: "synced" })) };
    } else {
      throw new Error(`unexpected CloudKit request ${path}`);
    }
    return { ok: true, json: async () => body };
  };
  const send = (request, sender = { id: "royal-test", url: pageURL }) => new Promise(resolve => {
    if (!messageListener(request, sender, resolve)) resolve("rejected-sender");
  });
  // A token kept by an earlier version, in session storage.
  session.cloudKitToken = "old-session-token";
  // And a hand-entered configuration from before 0.6.1 that matches Royal's own.
  local.cloudKitConfig = { ...ROYAL_CLOUDKIT };
  try {
    await import(`./background.mjs?worker-test`);
    assert.equal((await send({ action: "status" })).ok, true);
    assert.equal(local.cloudKitToken, "old-session-token", "an earlier version's sign-in carries over");
    assert.equal(session.cloudKitToken, undefined);
    assert.equal(await send({ action: "status" }, { id: "royal-test", url: "https://attacker.test" }), "rejected-sender");
    assert.equal(local.cloudKitConfig, undefined, "a hand-entered configuration is dropped");
    assert.equal((await send({ action: "configure", config: {} })).ok, false, "configuration can't be changed");
    assert.equal((await send({ action: "signIn" })).ok, true);
    assert.equal(local.cloudKitToken, "rotated-token");
    const diagnosis = await send({ action: "diagnose" });
    assert.match(diagnosis.message, /HTTP 401/);
    assert.equal(local.cloudKitToken, "rotated-token", "connection diagnosis leaves the real session unchanged");
    hostAccess = false;
    assert.match((await send({ action: "diagnose" })).message, /host access is not granted/);
    hostAccess = true;
    networkFails = true;
    const failedDiagnosis = await send({ action: "diagnose" });
    assert.match(failedDiagnosis.message, /no HTTP response/);
    assert.ok(!failedDiagnosis.message.includes("rotated-token"));
    assert.ok(!failedDiagnosis.message.includes("ckAPIToken="));
    networkFails = false;
    // CloudKit operations run one at a time and never return the token.
    const [first, second] = await Promise.all([send({ action: "sync" }), send({ action: "sync" })]);
    assert.equal(first.ok, true);
    assert.equal(second.ok, true);
    assert.equal(maximumActive, 1);
    assert.ok(!JSON.stringify(first).includes("rotated-token"));
    assert.equal((await send({ action: "read" })).ok, false, "the old probe operation is gone");
    await send({ action: "signOut" });
    assert.equal(local.cloudKitToken, undefined);

    // Sync with the sign-in gone (signed out, or cleared by an older version's
    // update) asks to sign in again without calling CloudKit.
    assert.equal((await send({ action: "signIn" })).ok, true);
    const enabled = await send({ action: "enableSync" });
    assert.equal(enabled.ok, true);
    assert.match(enabled.message, /^Synced\./);
    assert.equal(enabled.signInNeeded, false);
    await send({ action: "signOut" });
    let calls = 0;
    const counted = globalThis.fetch;
    globalThis.fetch = async (...args) => { calls++; return counted(...args); };
    const paused = await send({ action: "sync" });
    assert.equal(paused.signInNeeded, true);
    assert.match(paused.message, /sign in to iCloud again/);
    assert.equal(calls, 0);
    // Signing in again resumes it.
    assert.equal((await send({ action: "signIn" })).ok, true);
    const resumed = await send({ action: "sync" });
    assert.match(resumed.message, /^Synced\./);
    assert.equal(resumed.signInNeeded, false);

    // With sync on, Refresh All pulls other devices' seen posts before fetching feeds.
    requests.length = 0;
    const refreshed = await send({ action: "refreshAll" });
    assert.equal(refreshed.ok, true);
    assert.match(refreshed.syncMessage, /^Synced\./);
    const pulled = requests.findIndex(path => path.endsWith("records/changes"));
    const fetchedFeed = requests.findIndex(path => !path.startsWith("api.apple-cloudkit.com"));
    assert.ok(pulled >= 0 && fetchedFeed > pulled, `sync before feeds: ${requests.join(", ")}`);
  } finally {
    globalThis.fetch = savedFetch;
    delete globalThis.chrome;
  }
});

test("a sign-in made under a different hand-entered configuration is dropped", async () => {
  const local = { cloudKitToken: "development-token", cloudKitConfig: { ...ROYAL_CLOUDKIT, environment: "development" } };
  const storage = values => ({
    setAccessLevel: async () => {},
    get: async key => ({ [key]: values[key] }),
    set: async entries => Object.assign(values, entries),
    remove: async key => { delete values[key]; },
  });
  let messageListener;
  const pageURL = "chrome-extension://royal-test/index.html";
  globalThis.chrome = {
    runtime: { id: "royal-test", getURL: () => pageURL, sendMessage: async () => {}, onMessage: { addListener: fn => { messageListener = fn; } } },
    action: { onClicked: { addListener: () => {} } },
    storage: { local: storage(local), session: storage({}) },
    identity: { getRedirectURL: () => "https://royal-test.chromiumapp.org/cloudkit" },
  };
  try {
    await import("./background.mjs?other-configuration");
    const status = await new Promise(resolve => messageListener({ action: "status" }, { id: "royal-test", url: pageURL }, resolve));
    assert.equal(status.ok, true);
    assert.equal(local.cloudKitConfig, undefined);
    assert.equal(local.cloudKitToken, undefined);
  } finally {
    delete globalThis.chrome;
  }
});
