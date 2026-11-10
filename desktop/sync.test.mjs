import { test } from "node:test";
import assert from "node:assert/strict";
import { CloudKitClient } from "./cloudkit.mjs";
import { fakeCloudKit } from "./fake-cloudkit.mjs";
import { createLibrary, LIBRARY_KEY, accountLibraryKey } from "./store.mjs";
import { decodeRecord, startSync } from "./sync.mjs";
import { runSync, SyncPausedError } from "./sync-runner.mjs";

const CONFIG = { container: "iCloud.com.tinykings.Royal", environment: "development", apiToken: "public-token" };
const post = (source, id) => ({ source, id, title: `Title ${id}`, url: `https://example.com/${id}`, commentsUrl: `https://example.com/${id}#c`, label: source });

function memoryStorage() {
  const values = {};
  return {
    values,
    get: async key => ({ [key]: structuredClone(values[key]) }),
    set: async entries => { Object.assign(values, structuredClone(entries)); },
    remove: async key => { delete values[key]; },
  };
}

// One browser: its own storage, feed results, clock, and CloudKit session.
function device(server, { token, feeds = {} } = {}) {
  const storage = memoryStorage();
  let clock = 1_000_000;
  const session = { token };
  const library = createLibrary({
    storage, now: () => (clock += 1000),
    fetchFeed: async ({ source }) => ({ state: "ok", posts: feeds[source] ?? [] }),
  });
  const api = new CloudKitClient(CONFIG, { fetcher: server.fetch, getToken: async () => session.token, setToken: async value => { session.token = value; } });
  return {
    storage, library, api, session, feeds,
    async enable() {
      const account = await api.currentUser();
      await library.useSync({ account, container: CONFIG.container, environment: CONFIG.environment }, startSync);
      return this.sync();
    },
    sync: () => runSync({ api, library }),
    ids: async () => (await library.view()).saved.map(p => p.id),
  };
}

test("turning sync on imports local saves without overwriting remote records or tombstones", async () => {
  const server = fakeCloudKit();
  server.signIn("a-token", "_userA"); server.signIn("b-token", "_userA");
  const a = device(server, { token: "a-token" }), b = device(server, { token: "b-token" });
  await a.library.setSaved(post("hn", "shared"), true);
  await a.library.setSaved(post("hn", "onlyA"), true);
  await a.library.setSaved(post("hn", "shared"), false); // A's tombstone
  await b.library.setSaved(post("reddit", "shared"), true); // B saved it locally, never synced
  await b.library.setSaved(post("reddit", "onlyB"), true);
  assert.deepEqual(await a.enable(), { pulled: 0, pushed: 2, failed: 0, pending: 0 });
  const result = await b.enable();
  assert.equal(result.pending, 0);
  // The remote tombstone wins over B's unsynced import; B's new save is added.
  assert.deepEqual((await b.ids()).sort(), ["onlyA", "onlyB"]);
  await a.sync();
  assert.deepEqual((await a.ids()).sort(), ["onlyA", "onlyB"]);
  assert.equal(server.records("_userA").length, 3);
  // The local (unsynced) library stays as it was.
  assert.deepEqual(Object.keys(b.storage.values[LIBRARY_KEY].saved).sort(), ["onlyB", "shared"]);
});

test("saves and unsaves sync both ways; the last accepted intention wins a conflict", async () => {
  const server = fakeCloudKit();
  server.signIn("a", "_u"); server.signIn("b", "_u");
  const a = device(server, { token: "a" }), b = device(server, { token: "b" });
  await a.enable(); await b.enable();
  await a.library.setSaved(post("hn", "x"), true);
  await a.sync(); await b.sync();
  assert.deepEqual(await b.ids(), ["x"]);
  // Both change x while apart: A unsaves and syncs first, then B (still showing
  // the old revision) saves it again. B's push conflicts, pulls, and reapplies.
  await a.library.setSaved(post("hn", "x"), false);
  await b.library.setSaved(post("hn", "y"), true);
  await a.sync();
  await b.library.setSaved(post("hn", "x"), false);
  await b.library.setSaved(post("hn", "x"), true);
  const outcome = await b.sync();
  assert.equal(outcome.pending, 0);
  assert.ok(server.requests.some(r => r.operation === "records/modify" && r.body.operations.some(op => op.record.recordName === "saved.x")));
  await a.sync();
  assert.deepEqual(await a.ids(), ["x", "y"]);
  assert.deepEqual(await b.ids(), ["x", "y"]);
  const record = server.records("_u").find(r => r.recordName === "saved.x");
  assert.equal(record.fields.isSaved.value, 1);
  assert.match(record.fields.savedAt.value, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  assert.deepEqual(decodeRecord(record).entry.post.id, "x");
});

test("All refreshes replace the snapshot; a pending Mark all read applies on top of the newer one", async () => {
  const server = fakeCloudKit();
  server.signIn("a", "_u"); server.signIn("b", "_u");
  const a = device(server, { token: "a", feeds: { reddit: [post("reddit", "r1")], hn: [post("hn", "h1")] } });
  const b = device(server, { token: "b", feeds: { hn: [post("hn", "other")] } });
  await a.enable(); await b.enable();
  await a.library.refreshAll(); await a.sync(); await b.sync();
  let view = await b.library.view();
  assert.deepEqual(view.all.new.map(p => p.id), ["r1", "h1"]);
  assert.equal(view.all.refreshedAt, (await a.library.view()).all.refreshedAt);
  // A refreshes again (r2 arrives) while B, offline, marks all read.
  a.feeds.reddit = [post("reddit", "r2"), post("reddit", "r1")];
  await a.library.refreshAll(); await a.sync();
  await b.library.markAllRead();
  await b.sync();
  view = await b.library.view();
  assert.deepEqual(view.all.new.map(p => p.id), [], "B's mark read covers A's newer snapshot");
  assert.deepEqual(view.all.seen.map(p => p.id).sort(), ["h1", "r1", "r2"]);
  await a.sync();
  assert.deepEqual((await a.library.view()).all.new, []);
  // Seen merges by union: B's local-only refresh ids are kept too.
  const seen = JSON.parse(server.records("_u").find(r => r.recordName === "seen").fields.ids.value);
  assert.ok(["r1", "h1", "r2"].every(id => seen.includes(id)));
});

test("changes made offline stay pending until a later sync", async () => {
  const server = fakeCloudKit();
  server.signIn("a", "_u");
  const a = device(server, { token: "a" });
  await a.enable();
  server.offline = true;
  await a.library.setSaved(post("hn", "offline"), true);
  await assert.rejects(a.sync(), error => error.code === "NETWORK_ERROR");
  assert.equal((await a.library.view()).sync.pending, 1);
  server.offline = false;
  assert.equal((await a.sync()).pending, 0);
  assert.equal(server.records("_u").length, 1);
});

test("each Apple Account has its own library; a different account pauses sync", async () => {
  const server = fakeCloudKit();
  server.signIn("a", "_userA"); server.signIn("b", "_userB");
  const browser = device(server, { token: "a" });
  await browser.enable();
  await browser.library.setSaved(post("hn", "a-only"), true);
  await browser.sync();
  // Same browser, now signed in as B.
  browser.session.token = "b";
  await assert.rejects(browser.sync(), SyncPausedError);
  await browser.enable();
  assert.deepEqual(await browser.ids(), [], "B never sees A's saves");
  assert.equal(server.records("_userB").length, 0);
  assert.ok(browser.storage.values[accountLibraryKey({ environment: "development", container: CONFIG.container, account: "_userA" })]);
  await browser.library.useSync(null);
  assert.deepEqual(await browser.ids(), [], "turning sync off shows the local library");
});

test("a deleted zone is recreated and pending data pushed again", async () => {
  const server = fakeCloudKit();
  server.signIn("a", "_u");
  const a = device(server, { token: "a" });
  await a.enable();
  await a.library.setSaved(post("hn", "keep"), true);
  await a.sync();
  server.deleteZone("_u", "RoyalSync");
  await a.library.setSaved(post("hn", "new"), true);
  await a.sync();
  assert.deepEqual(server.records("_u").map(r => r.recordName).sort(), ["saved.new"]);
});
