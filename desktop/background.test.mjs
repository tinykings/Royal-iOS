import { test } from "node:test";
import assert from "node:assert/strict";
import { PROBE } from "./cloudkit.mjs";

test("worker isolates callers/accounts, serializes token use, and requires reread after conflict", async () => {
  const local = {}, session = {}, listeners = [];
  const pageURL = "chrome-extension://royal-test/index.html";
  const storage = values => ({
    setAccessLevel: async () => {},
    get: async key => ({ [key]: values[key] }),
    set: async entries => Object.assign(values, entries),
    remove: async key => { delete values[key]; },
  });
  let active = 0, maximumActive = 0, writes = 0, account = "account-a", failWrite = false;
  let messageListener;
  let hostAccess = true, networkFails = false;
  globalThis.chrome = {
    runtime: { id: "royal-test", getURL: () => pageURL, onMessage: { addListener: fn => { messageListener = fn; } } },
    action: { onClicked: { addListener: fn => listeners.push(fn) } },
    tabs: { create: async () => {} },
    permissions: { contains: async () => hostAccess },
    storage: { local: storage(local), session: storage(session) },
    identity: { getRedirectURL: () => "https://royal-test.chromiumapp.org/cloudkit", launchWebAuthFlow: async () => "https://royal-test.chromiumapp.org/cloudkit?ckWebAuthToken=initial-token" },
  };
  const savedFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
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
        ? { userRecordName: account, ckWebAuthToken: "rotated-token" }
        : { serverErrorCode: "AUTHENTICATION_REQUIRED", redirectURL: "https://idmsa.apple.com/login" };
    } else if (path.endsWith("records/lookup")) {
      body = { records: [{ ...PROBE, recordChangeTag: "revision", fields: { message: { value: "from-ios" } } }] };
    } else {
      writes++;
      assert.equal(JSON.parse(options.body).operations[0].operationType, "update");
      body = { records: [failWrite ? { recordName: PROBE.recordName, serverErrorCode: "CONFLICT" }
        : { ...PROBE, recordChangeTag: "new-revision", fields: { message: { value: "from-desktop" } } }] };
    }
    return { ok: true, json: async () => body };
  };
  const send = (request, sender = { id: "royal-test", url: pageURL }) => new Promise(resolve => {
    if (!messageListener(request, sender, resolve)) resolve("rejected-sender");
  });
  try {
    await import(`./background.mjs?worker-test`);
    assert.equal(await send({ action: "status" }, { id: "royal-test", url: "https://attacker.test" }), "rejected-sender");
    const config = { container: "iCloud.com.tinykings.Royal", apiToken: "public-api-token", environment: "development" };
    assert.equal((await send({ action: "configure", config })).ok, true);
    assert.equal((await send({ action: "signIn" })).ok, true);
    assert.equal(session.cloudKitToken, "rotated-token");
    const diagnosis = await send({ action: "diagnose" });
    assert.match(diagnosis.message, /HTTP 401/);
    assert.equal(session.cloudKitToken, "rotated-token", "connection diagnosis leaves the real session unchanged");
    hostAccess = false;
    assert.match((await send({ action: "diagnose" })).message, /host access is not granted/);
    hostAccess = true;
    networkFails = true;
    const failedDiagnosis = await send({ action: "diagnose" });
    assert.match(failedDiagnosis.message, /no HTTP response/);
    assert.ok(!failedDiagnosis.message.includes("rotated-token"));
    assert.ok(!failedDiagnosis.message.includes("ckAPIToken="));
    networkFails = false;
    assert.equal((await send({ action: "write", message: "hi" })).ok, false);
    const [first, second] = await Promise.all([send({ action: "read" }), send({ action: "read" })]);
    assert.equal(first.record.message, "from-ios");
    assert.equal(second.ok, true);
    assert.equal(maximumActive, 1);
    assert.ok(!JSON.stringify(first).includes("rotated-token"));
    failWrite = true;
    assert.equal((await send({ action: "write", message: "hi" })).ok, false);
    failWrite = false;
    assert.equal((await send({ action: "write", message: "hi" })).ok, false);
    assert.equal(writes, 1, "conflict invalidates the edit base");
    await send({ action: "read" });
    account = "account-b";
    assert.equal((await send({ action: "write", message: "hi" })).ok, false);
    assert.equal(writes, 1, "account switch cannot write using the other account's revision");
    await send({ action: "read" });
    assert.equal((await send({ action: "write", message: "hi" })).ok, true);
    await send({ action: "configure", config });
    assert.equal(session.cloudKitToken, undefined);
    assert.equal((await send({ action: "write", message: "hi" })).ok, false);
  } finally {
    globalThis.fetch = savedFetch;
    delete globalThis.chrome;
  }
});
