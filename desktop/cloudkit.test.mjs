import { test } from "node:test";
import assert from "node:assert/strict";
import { CloudKitClient, CloudKitError, appleSignInURL, callbackToken, validateConfig, describeCloudKitError } from "./cloudkit.mjs";

const config = { container: "iCloud.com.tinykings.Royal", apiToken: "public-api-token", environment: "development" };
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

test("identity uses public/users/caller while record requests remain private and adopt rotated tokens", async () => {
  const f = fixture([reply({ userRecordName: "user", ckWebAuthToken: "rotated" }), reply({ records: [], syncToken: "t" })]);
  assert.equal(await f.client.currentUser(), "user");
  assert.equal(f.token(), "rotated");
  await f.client.zoneChanges();
  assert.equal(f.calls[0].url.searchParams.get("ckWebAuthToken"), "user+/=token");
  assert.equal(f.calls[1].url.searchParams.get("ckWebAuthToken"), "rotated");
  assert.match(f.calls[0].url.pathname, /\/development\/public\/users\/caller$/);
  assert.equal(f.calls[0].options.method, "GET");
  assert.match(f.calls[1].url.pathname, /\/development\/private\/records\/changes$/);
  assert.equal(f.calls[0].options.redirect, "error");
  assert.equal(f.calls[0].options.cache, "no-store");
  assert.equal(f.calls[0].options.credentials, "omit");
});

test("caller accepts Apple's documented identity array and rejects missing/ambiguous identities", async () => {
  const f = fixture([reply({ users: [{ userRecordName: "documented-user", nameComponents: { givenName: "unused" } }] })]);
  assert.equal(await f.client.currentUser(), "documented-user");
  for (const value of [{ users: [] }, { users: [null] }, { users: [{ userRecordName: "a" }, { userRecordName: "b" }] }]) {
    await assert.rejects(fixture([reply(value)]).client.currentUser(), CloudKitError);
  }
});

test("authentication failure clears the prior session and retains only the redirect internally", async () => {
  const f = fixture([reply({ serverErrorCode: "AUTHENTICATION_REQUIRED", reason: "secret", redirectURL: "https://idmsa.apple.com/login" }, false)]);
  await assert.rejects(f.client.currentUser(), error => error.code === "AUTHENTICATION_REQUIRED" && !error.message.includes("secret"));
  assert.equal(f.token(), null);
});

test("malformed sync responses are errors, not empty results", async () => {
  for (const response of [null, [], {}, { records: [] }, { records: {}, syncToken: "t" }]) {
    await assert.rejects(fixture([reply(response)]).client.zoneChanges(), CloudKitError);
  }
  for (const response of [{}, { records: [] }]) {
    await assert.rejects(fixture([reply(response)]).client.modifySyncRecords([{ operationType: "create", record: {} }]), CloudKitError);
  }
});

test("network errors never leak credential-bearing request URLs", async () => {
  const client = new CloudKitClient(config, { getToken: async () => "secret-token", setToken: async () => {},
    fetcher: async url => { throw new Error(`failed ${url}`); } });
  await assert.rejects(client.currentUser(), error => {
    assert.equal(error.message, "NETWORK_ERROR");
    const description = describeCloudKitError(error);
    assert.match(description, /public\/users\/caller/);
    assert.match(description, /api\.apple-cloudkit\.com/);
    assert.ok(!description.includes("secret-token"));
    assert.ok(!description.includes("conflict"));
    return true;
  });
});

test("timeouts and HTTP failures get distinct safe diagnostics", async () => {
  const client = new CloudKitClient(config, { getToken: async () => null, setToken: async () => {},
    fetcher: async () => { throw Object.assign(new Error("secret URL"), { name: "TimeoutError" }); } });
  await assert.rejects(client.currentUser(), error => error.code === "TIMEOUT" && !describeCloudKitError(error).includes("secret URL"));
  const f = fixture([{ ok: false, status: 403, json: async () => ({ serverErrorCode: "ACCESS_DENIED", reason: "secret-token" }) }]);
  await assert.rejects(f.client.currentUser(), error => {
    const description = describeCloudKitError(error);
    assert.match(description, /HTTP 403/);
    assert.match(description, /allowed origin/);
    assert.ok(!description.includes("secret-token"));
    return true;
  });
});

test("default fetcher invokes the global fetch unbound, as browsers require", async () => {
  const original = globalThis.fetch;
  // Browsers throw "Illegal invocation" when native fetch is called as a method.
  globalThis.fetch = function (url) {
    if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
    return Promise.resolve({ ok: true, status: 200, json: async () => ({ users: [{ userRecordName: "_abc" }] }) });
  };
  try {
    const client = new CloudKitClient(config, { getToken: async () => null, setToken: async () => {} });
    assert.equal(await client.currentUser(), "_abc");
  } finally { globalThis.fetch = original; }
});
