import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_PREFERENCES, PREFERENCES_KEY, layoutFor, loadPreferences, normalizePreferences, opensComments, savePreferences } from "../shared/preferences.mjs";

const reddit = { source: "reddit", image: "https://i.redd.it/a.jpg" }, hn = { source: "hn" }, youtube = { source: "youtube", videoId: "abc" };

test("defaults match iOS: cards for Reddit and YouTube, clicks open the link, videos play in Royal", () => {
  assert.deepEqual(normalizePreferences(undefined), DEFAULT_PREFERENCES);
  assert.equal(layoutFor(reddit, DEFAULT_PREFERENCES), "card");
  assert.equal(layoutFor(youtube, DEFAULT_PREFERENCES), "card");
  assert.equal(layoutFor(hn, DEFAULT_PREFERENCES), "row");
  assert.equal(opensComments(reddit, DEFAULT_PREFERENCES), false);
  assert.equal(opensComments(hn, DEFAULT_PREFERENCES), false);
});

test("unknown or invalid stored values fall back one by one", () => {
  const preferences = normalizePreferences({ redditLayout: "row", hnOpen: "sideways", listWhilePlaying: "yes", extra: 1 });
  assert.deepEqual(preferences, { ...DEFAULT_PREFERENCES, redditLayout: "row" });
  assert.equal(normalizePreferences({ blurNSFW: "no" }).blurNSFW, true);
  assert.equal(normalizePreferences({ blurNSFW: false }).blurNSFW, false);
});

test("layout follows each source's choice; Saved and Hacker News stay rows", () => {
  const preferences = { ...DEFAULT_PREFERENCES, redditLayout: "row", youtubeLayout: "card" };
  assert.equal(layoutFor(reddit, preferences), "row");
  assert.equal(layoutFor(youtube, preferences), "card");
  assert.equal(layoutFor(youtube, preferences, { saved: true }), "row");
  assert.equal(layoutFor(hn, { ...preferences, redditLayout: "card" }), "row");
});

test("posts with no image are rows, even where cards are chosen", () => {
  assert.equal(layoutFor({ source: "reddit" }, DEFAULT_PREFERENCES), "row");
  assert.equal(layoutFor({ ...hn, image: "https://example.com/a.png" }, DEFAULT_PREFERENCES), "row");
});

test("rows while a video plays, only when chosen and videos play in Royal", () => {
  assert.equal(layoutFor(reddit, DEFAULT_PREFERENCES, { playing: true }), "row");
  assert.equal(layoutFor(reddit, { ...DEFAULT_PREFERENCES, listWhilePlaying: false }, { playing: true }), "card");
  assert.equal(layoutFor(reddit, { ...DEFAULT_PREFERENCES, youtubePlayback: "browser" }, { playing: true }), "card");
});

test("click target is per source; YouTube never opens comments", () => {
  const preferences = { ...DEFAULT_PREFERENCES, redditOpen: "comments", hnOpen: "link" };
  assert.equal(opensComments(reddit, preferences), true);
  assert.equal(opensComments(hn, preferences), false);
  assert.equal(opensComments(youtube, { ...preferences, hnOpen: "comments" }), false);
});

test("saved under one key and read back normalized", async () => {
  const data = {};
  const storage = { get: async key => ({ [key]: data[key] }), set: async values => Object.assign(data, values) };
  assert.deepEqual(await loadPreferences(storage), DEFAULT_PREFERENCES);
  const saved = await savePreferences(storage, { ...DEFAULT_PREFERENCES, hnOpen: "comments", bogus: true });
  assert.deepEqual(data[PREFERENCES_KEY], saved);
  assert.equal((await loadPreferences(storage)).hnOpen, "comments");
});
