import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fetchFeed, fetchSubreddits } from "./feeds.mjs";

const quiet = { info() {}, warn() {} };

test("desktop/sources.js is an exact copy of the root sources.js", async () => {
  const root = await readFile(new URL("../sources.js", import.meta.url), "utf8");
  const copy = await readFile(new URL("./sources.js", import.meta.url), "utf8");
  assert.ok(root === copy, "desktop/sources.js is stale. Run: cp sources.js desktop/sources.js");
});

function withFetch(handler, run) {
  const saved = globalThis.fetch;
  // Chromium's native fetch throws "Illegal invocation" unless called as a plain
  // function; Node's doesn't. Fail here if anything calls it as a method.
  globalThis.fetch = function (url, options) {
    assert.ok(this === undefined || this === globalThis, "fetch must not be called as a method");
    assert.equal(options?.credentials, "include", "provider requests must use the browser's cookies");
    return handler(new URL(url));
  };
  return run().finally(() => { globalThis.fetch = saved; });
}

const jsonResponse = (body, status = 200) => ({ ok: status < 400, status, url: "", json: async () => body, text: async () => JSON.stringify(body) });

test("Reddit, Hacker News and YouTube posts reach the page as display-only posts", () => withFetch(async url => {
  if (url.pathname.startsWith("/subreddits/mine/")) return jsonResponse({ data: { children: [{ data: { display_name: "a" } }], after: null } });
  if (url.pathname === "/best.json") return jsonResponse({ data: { children: [
    { data: { name: "t3_ok", title: "OK", subreddit: "a", permalink: "/r/a/comments/ok/", url: "https://example.com/", score: 3, num_comments: 1, created_utc: 5 } },
    { data: { name: "t3_bad", title: "Bad", subreddit: "a", permalink: "/r/a/comments/bad/", url: "javascript:alert(1)", score: 1, num_comments: 0, created_utc: 5 } },
  ] } });
  if (url.pathname === "/v0/topstories.json") return jsonResponse([7]);
  if (url.pathname === "/v0/item/7.json") return jsonResponse({ id: 7, title: "HN", time: 9, score: 2, descendants: 4 });
  if (url.host === "www.youtube.com") {
    const data = { contents: { twoColumnBrowseResultsRenderer: { tabs: [{ tabRenderer: { selected: true, content: { videoRenderer: { videoId: "abcdefghijk", title: { simpleText: "Video" }, ownerText: { simpleText: "Channel" }, publishedTimeText: { simpleText: "2 hours ago" } } } } }] } } };
    return { ok: true, status: 200, url: "https://www.youtube.com/feed/subscriptions", text: async () => `<script>var ytInitialData = ${JSON.stringify(data)};</script>` };
  }
  throw new Error(`unexpected ${url}`);
}, async () => {
  const reddit = await fetchFeed({ source: "reddit", options: { sort: "best" } }, { log: quiet, hasHostAccess: async () => true });
  assert.equal(reddit.state, "ok");
  assert.deepEqual(reddit.posts.map(post => post.id), ["t3_ok"], "non-http links are dropped");
  assert.equal(reddit.posts[0].commentsUrl, "https://www.reddit.com/r/a/comments/ok/");
  const hn = await fetchFeed({ source: "hn", options: { list: "top" } }, { log: quiet });
  assert.deepEqual(hn.posts.map(post => [post.title, post.url]), [["HN", "https://news.ycombinator.com/item?id=7"]]);
  const youtube = await fetchFeed({ source: "youtube", options: { feed: "subscriptions" } }, { log: quiet });
  assert.equal(youtube.state, "ok");
  assert.deepEqual(youtube.posts.map(post => [post.title, post.label, post.published]), [["Video", "Channel", "2 hours ago"]]);
}));

test("Hacker News loads the same first 30 stories iOS shows", () => withFetch(async url => {
  if (url.pathname === "/v0/topstories.json") return jsonResponse(Array.from({ length: 100 }, (_, i) => i + 1));
  const id = Number(url.pathname.match(/^\/v0\/item\/(\d+)\.json$/)?.[1]);
  if (id) return jsonResponse({ id, title: `HN ${id}`, time: 9, score: 2, descendants: 0 });
  throw new Error(`unexpected ${url}`);
}, async () => {
  const hn = await fetchFeed({ source: "hn", options: { list: "top" } }, { log: quiet });
  assert.deepEqual(hn.posts.map(post => post.id), Array.from({ length: 30 }, (_, i) => `hn_${i + 1}`));
}));

test("logged-out, redirected, and unpermitted feeds report which site to fix", () => withFetch(async url => {
  if (url.host === "www.reddit.com") return jsonResponse({ message: "Forbidden" }, 403);
  if (url.pathname === "/") throw new TypeError("Failed to fetch");
  return { ok: true, status: 200, url: "https://www.youtube.com/feed/subscriptions", text: async () => `<script>ytcfg.set({"LOGGED_IN":false})</script>` };
}, async () => {
  const reddit = await fetchFeed({ source: "reddit" }, { log: quiet });
  assert.equal(reddit.state, "notLoggedIn");
  assert.match(reddit.message, /Log into Reddit/);
  assert.equal(reddit.login, "https://www.reddit.com/login/");
  const youtube = await fetchFeed({ source: "youtube", options: { feed: "subscriptions" } }, { log: quiet });
  assert.equal(youtube.state, "notLoggedIn");
  assert.match(youtube.message, /Log into YouTube/);
  const home = await fetchFeed({ source: "youtube", options: { feed: "home" } }, { log: quiet });
  assert.equal(home.state, "error");
  assert.match(home.message, /consent/);
  const denied = await fetchFeed({ source: "reddit" }, { log: quiet, hasHostAccess: async origin => origin !== "https://www.reddit.com/*" });
  assert.equal(denied.state, "noAccess");
  assert.match(denied.message, /www\.reddit\.com/);
}));

test("a Reddit network-security block is not reported as a login problem", () => withFetch(
  async () => jsonResponse("Your request has been blocked by network security.", 403),
  async () => {
    const reddit = await fetchFeed({ source: "reddit" }, { log: quiet });
    assert.equal(reddit.state, "error");
    assert.match(reddit.message, /network security refused \/subreddits\/mine\/subscriber\.json/);
  }));

test("feed requests are bounded to known sources and options", async () => {
  await assert.rejects(fetchFeed({ source: "https://evil.test" }, { log: quiet }), /Unknown feed source/);
  await assert.rejects(fetchFeed({ source: "reddit", options: { sort: "new" } }, { log: quiet }), /Invalid Reddit option/);
  await assert.rejects(fetchFeed({ source: "youtube", options: { url: "https://evil.test" } }, { log: quiet }), /Invalid YouTube option/);
});

test("the Reddit tab can show one followed subreddit's Top", () => withFetch(async url => {
  if (url.pathname.startsWith("/subreddits/mine/")) return jsonResponse({ data: { children: [
    { data: { display_name: "zeta" } }, { data: { display_name: "Alpha" } },
    { data: { display_name: "u_someone", subreddit_type: "user" } }, { data: { display_name: "adult", over18: true } },
  ], after: null } });
  if (url.pathname === "/r/swift/top.json") {
    assert.equal(url.searchParams.get("t"), "day");
    return jsonResponse({ data: { children: [
      { data: { name: "t3_s", title: "S", subreddit: "swift", permalink: "/r/swift/comments/s/", url: "https://example.com/", score: 1, num_comments: 0, created_utc: 5 } },
    ] } });
  }
  throw new Error(`unexpected ${url}`);
}, async () => {
  assert.deepEqual((await fetchSubreddits({ log: quiet })).subreddits, ["Alpha", "zeta"]);
  assert.deepEqual((await fetchSubreddits({ log: quiet, hasHostAccess: async () => false })).subreddits, []);
  const one = await fetchFeed({ source: "reddit", options: { sort: "top", timeframe: "day", subreddit: "swift" } }, { log: quiet });
  assert.deepEqual(one.posts.map(post => post.label), ["r/swift"]);
  await assert.rejects(fetchFeed({ source: "reddit", options: { subreddit: "../evil" } }, { log: quiet }), /Invalid Reddit option/);
  await assert.rejects(fetchFeed({ source: "reddit", options: { subreddit: ["swift"] } }, { log: quiet }), /Invalid Reddit option/);
}));
