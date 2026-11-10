import { test } from "node:test";
import assert from "node:assert/strict";
import { CloudKitClient, CloudKitError, PROBE, appleSignInURL, callbackToken, validateConfig } from "./cloudkit.mjs";

const config = { container: "iCloud.com.tinykings.Royal", apiToken: "public-api-token", environment: "development" };
const record = { ...PROBE, recordChangeTag: "revision-1", fields: { message: { value: "Hello" } } };
const reply = (value, ok = true) => ({ ok, json: async () => value });
function fixture(responses, initialToken = "user+/=token") {
  let token = initialToken;
  const calls = [];
  const client = new CloudKitClient(config, {
    getToken: async () => token,
    setToken: async value => { token = value; },
    fetcher: async (url, options) => { calls.push({ url: new URL(url), options }); return responses.shift(); },
  });
  return { client, calls, token: () => token };
}

test("configuration cannot alter the CloudKit path or select a non-private database", () => {
  for (const container of ["iCloud.test/production/public", "iCloud.test?x", "other.test"]) {
    assert.throws(() => validateConfig({ ...config, container }));
  }
  assert.throws(() => validateConfig({ ...config, environment: "../public" }));
  assert.throws(() => validateConfig({ ...config, apiToken: " " }));
});

test("authentication redirects must belong to Apple over HTTPS", () => {
  assert.equal(appleSignInURL("https://idmsa.apple.com/login"), "https://idmsa.apple.com/login");
  for (const value of ["http://apple.com/login", "https://apple.com.attacker.test", "https://user:pass@apple.com", "https://apple.com:8443"]) {
    assert.throws(() => appleSignInURL(value));
  }
});

test("callback accepts only the configured origin/path and one non-empty token", () => {
  const callback = "https://example.chromiumapp.org/cloudkit";
  assert.equal(callbackToken(`${callback}?ckWebAuthToken=a%2Bb%2F%3D`, callback), "a+b/=");
  for (const value of ["https://attacker.test/cloudkit?ckWebAuthToken=x", `${callback}/other?ckWebAuthToken=x`, callback,
    `${callback}?ckWebAuthToken=`, `${callback}?ckWebAuthToken=a&ckWebAuthToken=b`]) assert.throws(() => callbackToken(value, callback));
});

test("private requests encode tokens, disable redirects/cache/cookies, and adopt rotated tokens", async () => {
  const f = fixture([reply({ userRecordName: "user", ckWebAuthToken: "rotated" }), reply({ records: [record] })]);
  assert.equal(await f.client.currentUser(), "user");
  assert.equal(f.token(), "rotated");
  await f.client.readProbe();
  assert.equal(f.calls[0].url.searchParams.get("ckWebAuthToken"), "user+/=token");
  assert.equal(f.calls[1].url.searchParams.get("ckWebAuthToken"), "rotated");
  assert.match(f.calls[1].url.pathname, /\/development\/private\/records\/lookup$/);
  assert.equal(f.calls[0].options.redirect, "error");
  assert.equal(f.calls[0].options.cache, "no-store");
  assert.equal(f.calls[0].options.credentials, "omit");
});

test("authentication failure clears the prior session and retains only the redirect internally", async () => {
  const f = fixture([reply({ serverErrorCode: "AUTHENTICATION_REQUIRED", reason: "secret", redirectURL: "https://idmsa.apple.com/login" }, false)]);
  await assert.rejects(f.client.currentUser(), error => error.code === "AUTHENTICATION_REQUIRED" && !error.message.includes("secret"));
  assert.equal(f.token(), null);
});

test("only record-level NOT_FOUND is an absent probe", async () => {
  const missing = fixture([reply({ records: [{ recordName: PROBE.recordName, serverErrorCode: "NOT_FOUND" }] })]);
  assert.equal(await missing.client.readProbe(), null);
  for (const response of [reply({ serverErrorCode: "NOT_FOUND" }, false), reply({ records: [{ recordName: PROBE.recordName, serverErrorCode: "ACCESS_DENIED" }] })]) {
    const f = fixture([response]);
    await assert.rejects(f.client.readProbe(), CloudKitError);
  }
});

test("writes use create or revision-checked update, never force overwrite", async () => {
  const f = fixture([reply({ records: [record] }), reply({ records: [record] })]);
  await f.client.writeProbe(" desktop ", null);
  await f.client.writeProbe("desktop", record);
  const operations = f.calls.map(call => JSON.parse(call.options.body).operations[0]);
  assert.equal(operations[0].operationType, "create");
  assert.equal(operations[0].record.fields.message.value, "desktop");
  assert.equal(operations[0].record.recordChangeTag, undefined);
  assert.equal(operations[1].operationType, "update");
  assert.equal(operations[1].record.recordChangeTag, "revision-1");
});

test("per-record conflicts remain failures even on HTTP success", async () => {
  const f = fixture([reply({ records: [{ recordName: PROBE.recordName, serverErrorCode: "CONFLICT", reason: "token-secret" }] })]);
  await assert.rejects(f.client.writeProbe("desktop", record), error => error.code === "CONFLICT" && !error.message.includes("token-secret"));
});

test("malformed responses cannot become a valid read or successful write", async () => {
  for (const response of [null, [], {}, { records: [] }, { records: [{}] }, { records: [{ ...record, recordName: "another-record" }] },
    { records: [{ ...record, recordChangeTag: undefined }] }]) {
    const f = fixture([reply(response)]);
    await assert.rejects(f.client.readProbe(), CloudKitError);
  }
});

test("network errors never leak credential-bearing request URLs", async () => {
  const client = new CloudKitClient(config, { getToken: async () => "secret-token", setToken: async () => {},
    fetcher: async url => { throw new Error(`failed ${url}`); } });
  await assert.rejects(client.currentUser(), error => error.message === "NETWORK_ERROR");
});

test("empty/oversized messages and writes with no valid revision never reach the network", async () => {
  const f = fixture([]);
  for (const message of ["", " ", "a".repeat(501)]) await assert.rejects(f.client.writeProbe(message, null));
  await assert.rejects(f.client.writeProbe("hi", { ...record, recordChangeTag: undefined }));
  assert.equal(f.calls.length, 0);
});
