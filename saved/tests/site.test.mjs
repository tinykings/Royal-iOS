import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { CloudKitClient } from "../shared/cloudkit.mjs";
import { fakeCloudKit } from "./fake-cloudkit.mjs";
import { SIGN_IN_STARTED_KEY, TOKEN_KEY, createSite, takeCallback } from "../site.mjs";

const CONFIG = { container: "iCloud.com.tinykings.Royal", environment: "production", apiToken: "site-token" };
const SITE = "https://royal.tinyk.ing/";
const post = (source, id) => ({ source, id, title: `Title ${id}`, url: `https://example.com/${id}`, commentsUrl: `https://example.com/${id}#c`, label: source });
const str = value => ({ value, type: "STRING" });
const int = value => ({ value, type: "INT64" });

function webStorage() {
  const values = new Map();
  return {
    values,
    getItem: key => (values.has(key) ? values.get(key) : null),
    setItem: (key, value) => { values.set(key, String(value)); },
    removeItem: key => { values.delete(key); },
  };
}

function browser(server, clock = { now: 1_800_000_000_000 }) {
  const storage = webStorage(), pending = webStorage();
  const site = createSite({ storage, pending, fetcher: server.fetch, config: CONFIG, now: () => (clock.now += 1000) });
  return { storage, pending, site, clock };
}

// Another client (iOS) writing records straight to CloudKit.
async function phone(server, token, operations) {
  const api = new CloudKitClient(CONFIG, { fetcher: server.fetch, getToken: async () => token, setToken: async () => {} });
  await api.ensureSyncZone();
  return api.modifySyncRecords(operations.map(record => ({ operationType: "create", record })));
}
const savedRecord = (p, savedAt, isSaved = 1) => ({
  recordName: `saved.${p.id}`, recordType: "RoyalSavedPost",
  fields: { postID: str(p.id), post: str(JSON.stringify(p)), savedAt: str(savedAt), isSaved: int(isSaved), schemaVersion: int(1) },
});

async function signIn(b, server, token, user) {
  const url = await b.site.beginSignIn();
  assert.equal(url, "https://idmsa.apple.com/login");
  server.signIn(token, user);
  const callback = takeCallback(`${SITE}?ckWebAuthToken=${token}&ckSession=x`, { pending: b.pending, now: b.clock.now });
  assert.equal(callback.cleanURL, SITE);
  return b.site.finishSignIn(callback.token);
}

test("signing in shows the phone's saved posts, newest first, without seen or All records", async () => {
  const server = fakeCloudKit();
  server.signIn("ios", "_u");
  await phone(server, "ios", [
    savedRecord(post("reddit", "t3_old"), "2026-11-01T10:00:00.000Z"),
    savedRecord(post("youtube", "yt_new"), "2026-11-02T10:00:00.000Z"),
    savedRecord(post("hn", "hn_gone"), "2026-11-03T10:00:00.000Z", 0),
    { recordName: "seen", recordType: "RoyalSeen", fields: { ids: str('["a"]'), sources: str('["hn"]'), schemaVersion: int(1) } },
  ]);
  const b = browser(server);
  const result = await signIn(b, server, "web", "_u");
  assert.equal(result.ok, true);
  assert.equal(result.signedIn, true);
  assert.deepEqual(result.saved.map(p => p.id), ["yt_new", "t3_old"]);
  const stored = [...b.storage.values.entries()].find(([key]) => key.startsWith("royalLibrary:"));
  assert.deepEqual(JSON.parse(stored[1]).seen, []);
  assert.equal(b.storage.values.get(TOKEN_KEY), '"web"');
});

test("unsaving syncs a tombstone and never writes seen or All", async () => {
  const server = fakeCloudKit();
  server.signIn("ios", "_u");
  await phone(server, "ios", [savedRecord(post("hn", "hn_1"), "2026-11-01T10:00:00.000Z")]);
  const b = browser(server);
  await signIn(b, server, "web", "_u");
  let changed = 0;
  b.site.onLocalChange = () => { changed++; };
  const view = await b.site.setSaved(post("hn", "hn_1"), false);
  assert.deepEqual(view.saved, []);
  assert.equal(view.sync.pending, 1);
  assert.equal(changed, 1);
  const synced = await b.site.sync();
  assert.equal(synced.sync.pending, 0);
  const records = server.records("_u");
  assert.deepEqual(records.map(r => r.recordName), ["saved.hn_1"]);
  assert.equal(records[0].fields.isSaved.value, 0);
  const writes = server.requests.filter(r => r.operation === "records/modify").flatMap(r => r.body.operations.map(op => op.record.recordName));
  assert.ok(writes.every(name => name.startsWith("saved.")));
});

test("a token in the address is refused unless this tab started the sign-in recently", () => {
  const pending = webStorage();
  const forged = takeCallback(`${SITE}?ckWebAuthToken=someone-else`, { pending, now: 1000 });
  assert.deepEqual(forged, { cleanURL: SITE, token: null, refused: true });

  pending.setItem(SIGN_IN_STARTED_KEY, "1000");
  const late = takeCallback(`${SITE}?ckWebAuthToken=t`, { pending, now: 1000 + 16 * 60 * 1000 });
  assert.equal(late.refused, true);

  pending.setItem(SIGN_IN_STARTED_KEY, "1000");
  assert.deepEqual(takeCallback(`${SITE}?ckWebAuthToken=t`, { pending, now: 2000 }), { cleanURL: SITE, token: "t", refused: false });
  // The marker is used once.
  assert.equal(takeCallback(`${SITE}?ckWebAuthToken=t`, { pending, now: 3000 }).refused, true);
  assert.equal(takeCallback(`${SITE}?other=1`, { pending, now: 3000 }), null);
});

test("an expired sign-in keeps changes pending until signing in again", async () => {
  const server = fakeCloudKit();
  server.signIn("ios", "_u");
  await phone(server, "ios", [savedRecord(post("hn", "hn_1"), "2026-11-01T10:00:00.000Z")]);
  const b = browser(server);
  await signIn(b, server, "web", "_u");
  await b.site.setSaved(post("hn", "hn_1"), false);
  server.signIn("web", undefined); // Apple expires the token.
  const paused = await b.site.sync();
  assert.equal(paused.signInNeeded, true);
  assert.equal(paused.signedIn, false);
  assert.equal(paused.sync.pending, 1);
  const again = await signIn(b, server, "web2", "_u");
  assert.equal(again.sync.pending, 0);
  assert.equal(server.records("_u")[0].fields.isSaved.value, 0);
});

test("signing out forgets the token and this browser's copy", async () => {
  const server = fakeCloudKit();
  server.signIn("ios", "_u");
  await phone(server, "ios", [savedRecord(post("hn", "hn_1"), "2026-11-01T10:00:00.000Z")]);
  const b = browser(server);
  await signIn(b, server, "web", "_u");
  const view = await b.site.signOut();
  assert.equal(view.signedIn, false);
  assert.deepEqual(view.saved, []);
  assert.deepEqual([...b.storage.values.keys()].filter(key => key !== "royalLibrary"), []);
  assert.equal(server.records("_u").length, 1);
});

test("a different Apple Account than the one syncing pauses sync", async () => {
  const server = fakeCloudKit();
  const b = browser(server);
  await signIn(b, server, "a", "_a");
  server.signIn("a", "_b");
  const result = await b.site.sync();
  assert.match(result.message, /different Apple Account/);
});

test("shared files match the extension's when a Royal-iOS checkout is next to this one", t => {
  const root = fileURLToPath(new URL("..", import.meta.url));
  const extension = `${root}../Royal-iOS/desktop/`;
  if (!existsSync(extension)) return t.skip("No ../Royal-iOS checkout.");
  for (const file of readdirSync(`${root}shared`)) {
    assert.ok(readFileSync(`${root}shared/${file}`).equals(readFileSync(extension + file)), `shared/${file} differs; run scripts/update-shared.sh`);
  }
  assert.ok(readFileSync(`${root}tests/fake-cloudkit.mjs`).equals(readFileSync(`${extension}fake-cloudkit.mjs`)));
});
