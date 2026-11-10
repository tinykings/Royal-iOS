import { test } from "node:test";
import assert from "node:assert/strict";
import { allPosts, applyAllRefresh, emptyState, interleave, markAllRead, normalizePost, savedPosts, SEEN_LIMIT, setSaved, splitByRefresh } from "./library.mjs";
import { createLibrary, LIBRARY_KEY } from "./store.mjs";

const post = (source, id, extra = {}) => ({ source, id, title: id, url: `https://example.com/${id}`, commentsUrl: `https://example.com/${id}#c`, label: source, ...extra });
const ok = posts => ({ state: "ok", posts });
const ids = posts => posts.map(p => p.id);

test("All alternates sources in Reddit, HN, YouTube order and keeps each link once", () => {
  const shared = { url: "https://example.com/same" };
  const out = interleave([[post("reddit", "r1"), post("reddit", "r2", shared)], [post("hn", "h1", shared), post("hn", "h2")], [post("youtube", "y1")]]);
  assert.deepEqual(ids(out), ["r1", "h1", "y1", "h2"]);
});

test("the first refresh is all new; the next splits new from earlier like iOS", () => {
  let state = applyAllRefresh(emptyState(), { reddit: ok([post("reddit", "r1")]), hn: ok([post("hn", "h1")]), youtube: ok([post("youtube", "y1")]) }, 1_000_000);
  assert.deepEqual(ids(splitByRefresh(state).new), ["r1", "h1", "y1"]);
  state = applyAllRefresh(state, {
    reddit: ok([post("reddit", "r2"), post("reddit", "r1")]),
    hn: ok([post("hn", "h1")]),
    youtube: ok([post("youtube", "y2"), post("youtube", "y1"), post("youtube", "y0")]),
  }, 2_000_000);
  const split = splitByRefresh(state);
  // y0 is below the newest seen video, so it's earlier even though it's unseen.
  assert.deepEqual(ids(split.new), ["r2", "y2"]);
  assert.deepEqual(ids(split.seen), ["h1", "r1", "y1", "y0"]);
  assert.equal(state.all.previousRefresh, 1_000_000);
});

test("a failed source keeps its earlier posts and records why; a new source isn't all new", () => {
  let state = applyAllRefresh(emptyState(), { reddit: ok([post("reddit", "r1")]), hn: ok([post("hn", "h1")]), youtube: { state: "notLoggedIn", message: "Log into YouTube", login: "https://www.youtube.com/" } }, 1);
  assert.equal(state.all.errors.youtube.state, "notLoggedIn");
  state = applyAllRefresh(state, { reddit: { state: "error", message: "boom" }, hn: ok([post("hn", "h2")]), youtube: ok([post("youtube", "y1")]) }, 2);
  assert.deepEqual(ids(state.all.lists.reddit), ["r1"]);
  assert.deepEqual(Object.keys(state.all.errors), ["reddit"]);
  // YouTube just logged in: its posts mix in with the earlier ones.
  assert.deepEqual(ids(splitByRefresh(state).new), ["h2"]);
});

test("YouTube without any seen video falls back to its publish time", () => {
  let state = applyAllRefresh(emptyState(), { reddit: ok([]), hn: ok([]), youtube: ok([post("youtube", "old")]) }, 10_000);
  state = applyAllRefresh(state, { reddit: ok([]), hn: ok([]), youtube: ok([post("youtube", "fresh", { publishedAt: 20 }), post("youtube", "stale", { publishedAt: 5 })]) }, 30_000);
  assert.deepEqual(ids(splitByRefresh(state).new), ["fresh"]);
});

test("mark all read moves everything to earlier and the next refresh shows only arrivals", () => {
  let state = applyAllRefresh(emptyState(), { reddit: ok([post("reddit", "r1")]), hn: ok([]), youtube: ok([]) }, 1);
  state = markAllRead(state, 5);
  assert.deepEqual(splitByRefresh(state).new, []);
  assert.equal(state.hasMarkedRead, true);
  state = applyAllRefresh(state, { reddit: ok([post("reddit", "r2"), post("reddit", "r1")]), hn: ok([]), youtube: ok([]) }, 9);
  assert.deepEqual(ids(splitByRefresh(state).new), ["r2"]);
});

test("seen ids are capped, keeping the most recent", () => {
  const many = Array.from({ length: SEEN_LIMIT + 5 }, (_, i) => post("hn", `h${i}`));
  const state = applyAllRefresh(emptyState(), { reddit: ok([]), hn: ok(many), youtube: ok([]) }, 1);
  assert.equal(state.seen.length, SEEN_LIMIT);
  assert.equal(state.seen.at(-1), `h${SEEN_LIMIT + 4}`);
});

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

function memoryStorage() {
  const values = {};
  return { values, get: async key => ({ [key]: structuredClone(values[key]) }), set: async entries => { Object.assign(values, structuredClone(entries)); } };
}

test("the store serializes updates, shares one refresh, and keeps All apart from source fetches", async () => {
  const storage = memoryStorage();
  let fetches = 0, release;
  const gate = new Promise(resolve => { release = resolve; });
  const library = createLibrary({
    storage, now: () => 1000,
    fetchFeed: async ({ source }) => { fetches++; await gate; return ok([post(source, `${source}1`)]); },
  });
  const first = library.refreshAll(), second = library.refreshAll();
  // A save made while the refresh is fetching must survive it.
  await library.setSaved(post("hn", "kept"), true);
  release();
  const [a, b] = await Promise.all([first, second]);
  assert.equal(fetches, 3, "one fetch per source for both refresh calls");
  assert.deepEqual(ids(a.all.new), ["reddit1", "hn1", "youtube1"]);
  assert.deepEqual(a, b);
  assert.deepEqual(ids(a.saved), ["kept"]);
  assert.equal(storage.values[LIBRARY_KEY].all.refreshedAt, 1000);
  assert.deepEqual(ids(allPosts(storage.values[LIBRARY_KEY])), ["reddit1", "hn1", "youtube1"]);
});
