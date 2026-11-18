import { test } from "node:test";
import assert from "node:assert/strict";
import { emptyState, normalizePost, savedPosts, setSaved } from "../shared/library.mjs";
import { createLibrary, LIBRARY_KEY } from "../shared/store.mjs";

const post = (source, id, extra = {}) => ({ source, id, title: id, url: `https://example.com/${id}`, commentsUrl: `https://example.com/${id}#c`, label: source, ...extra });
const ids = posts => posts.map(p => p.id);

test("saves are newest first, unsaves leave tombstones, and posts are sanitized", () => {
  let state = setSaved(emptyState(), post("hn", "a"), true, new Date("2026-11-10T10:00:00Z"));
  state = setSaved(state, post("reddit", "b"), true, new Date("2026-11-10T11:00:00Z"));
  assert.deepEqual(ids(savedPosts(state)), ["b", "a"]);
  state = setSaved(state, post("hn", "a"), false, new Date("2026-11-10T12:00:00Z"));
  assert.deepEqual(ids(savedPosts(state)), ["b"]);
  assert.equal(state.saved.a.isSaved, false);
  assert.equal(state.saved.a.savedAt, "2026-11-10T12:00:00.000Z");
  assert.equal(setSaved(state, post("reddit", "b"), true), state, "saving twice is a no-op");
  assert.throws(() => setSaved(state, post("hn", "x", { url: "javascript:alert(1)" }), true), /Invalid post/);
  assert.equal(normalizePost(post("hn", "../x")), null);
  assert.equal(normalizePost(post("reddit", "i", { image: "http://insecure.test/x.png" })).image, "http://insecure.test/x.png");
});

test("a video imported from Watch Later keeps its mark through an unsave", () => {
  const video = post("youtube", "yt_abcdefghijk", { videoId: "abcdefghijk", watchLater: true });
  let state = setSaved(emptyState(), video, true, new Date("2026-11-10T10:00:00Z"));
  assert.equal(savedPosts(state)[0].watchLater, true);
  state = setSaved(state, { ...video, watchLater: undefined }, false, new Date("2026-11-10T11:00:00Z"));
  assert.equal(state.saved.yt_abcdefghijk.post.watchLater, true);
  assert.equal("watchLater" in normalizePost(post("youtube", "v", { watchLater: "yes" })), false);
});

function memoryStorage() {
  const values = {};
  return { values, get: async key => ({ [key]: structuredClone(values[key]) }), set: async entries => { Object.assign(values, structuredClone(entries)); }, remove: async key => { delete values[key]; } };
}

test("the store serializes updates, so overlapping saves are all kept", async () => {
  const storage = memoryStorage();
  const library = createLibrary({ storage, now: () => 1000 });
  const views = await Promise.all(["a", "b", "c"].map(id => library.setSaved(post("hn", id), true)));
  assert.deepEqual(ids(views.at(-1).saved).sort(), ["a", "b", "c"]);
  assert.deepEqual(Object.keys(storage.values[LIBRARY_KEY].saved).sort(), ["a", "b", "c"]);
  assert.equal("all" in storage.values[LIBRARY_KEY], false);
});

test("a post's channel is kept, so a save round-tripped through the web loses nothing", () => {
  const video = post("youtube", "yt_abcdefghijk", { videoId: "abcdefghijk", channelId: "UC1234567890123456789012" });
  assert.equal(normalizePost(video).channelId, "UC1234567890123456789012");
  assert.equal("channelId" in normalizePost(post("youtube", "v", { channelId: 5 })), false);
});
