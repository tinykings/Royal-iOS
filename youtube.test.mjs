import test from "node:test";
import assert from "node:assert/strict";
import { fetchYouTube, parseYouTubeSubscriptions, NotLoggedInError, markSeen } from "./sources.js";

const video = (id = "abcdefghijk") => ({ videoRenderer: {
  videoId: id, title: { runs: [{ text: 'Video "title" } \\ test' }] },
  ownerText: { runs: [{ text: "Channel" }] }, publishedTimeText: { simpleText: "2 hours ago" },
} });
const page = (contents, extra = {}) => `<script>var ytInitialData = ${JSON.stringify({ contents, ...extra })};</script>`;

test("YouTube parses subscriptions, escaped titles, deduplication, selected tab, and limits", () => {
  const html = page({ twoColumnBrowseResultsRenderer: { tabs: [
    { tabRenderer: { content: video("xxxxxxxxxxx") } },
    { tabRenderer: { selected: true, content: { items: [video(), video(), video("12345678901"), video("invalid")] } } },
  ] } });
  const posts = parseYouTubeSubscriptions(html);
  assert.equal(posts.length, 2);
  assert.equal(posts[0].source, "youtube");
  assert.equal(posts[0].id, "yt_abcdefghijk");
  assert.equal(posts[0].title, 'Video "title" } \\ test');
  assert.equal(posts[0].label, "Channel");
  assert.equal(posts[0].published, "2 hours ago");
  assert.equal(posts[0].image, "https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg");
  assert.equal(posts[0].url, "https://www.youtube.com/watch?v=abcdefghijk");
  assert.equal(parseYouTubeSubscriptions(html, 1).length, 1);
  assert.equal(markSeen(posts, { youtube: [posts[0].id] }).posts[0].seen, true);
});

test("YouTube ignores ranked shelves without consuming limits or hiding chronological duplicates", () => {
  const html = page({ richGridRenderer: { contents: [
    { richSectionRenderer: { content: { richShelfRenderer: {
      title: { runs: [{ text: "Most relevant" }] }, contents: [video("ranked00001"), video()],
    } } } },
    { shelfRenderer: { title: { simpleText: "Most relevant" }, content: { items: [video("ranked00002")] } } },
    { itemSectionRenderer: {
      header: { itemSectionHeaderRenderer: { title: { simpleText: "Most relevant" } } }, contents: [video("ranked00003")],
    } },
    { shelfRenderer: { title: { simpleText: "Today" }, content: { items: [video()] } } },
    { richItemRenderer: { content: video("12345678901") } },
  ] } });
  assert.deepEqual(parseYouTubeSubscriptions(html).map((p) => p.videoId), ["abcdefghijk", "12345678901"]);
  assert.equal(parseYouTubeSubscriptions(html, 1)[0].videoId, "abcdefghijk");
});

test("YouTube skips in-feed ads that wrap videos from unsubscribed channels", () => {
  const html = page({ richGridRenderer: { contents: [
    { richItemRenderer: { content: { adSlotRenderer: { fulfillmentContent: { fulfilledLayout: {
      inFeedAdLayoutRenderer: { renderingContent: video("advideo0001") },
    } } } } } },
    { richItemRenderer: { content: { inFeedAdLayoutRenderer: { renderingContent: video("advideo0002") } } } },
    { richItemRenderer: { content: video() } },
  ] } });
  assert.deepEqual(parseYouTubeSubscriptions(html).map((p) => p.videoId), ["abcdefghijk"]);
});

test("YouTube supports current lockup renderers and window assignment", () => {
  const html = page({ items: [{ lockupViewModel: {
    contentId: "abcdefghijk", contentType: "LOCKUP_CONTENT_TYPE_VIDEO",
    metadata: { lockupMetadataViewModel: {
      title: { content: "New layout" },
      metadata: { contentMetadataViewModel: { metadataRows: [
        { metadataParts: [{ text: { content: "Creator" } }] },
        { metadataParts: [{ text: { content: "12K views" } }, { text: { content: "3 days ago" } }] },
      ] } },
    } },
  } }] }).replace("var ytInitialData", 'window["ytInitialData"]');
  assert.equal(parseYouTubeSubscriptions(html)[0].title, "New layout");
  assert.equal(parseYouTubeSubscriptions(html)[0].label, "Creator");
  assert.equal(parseYouTubeSubscriptions(html)[0].published, "3 days ago");
  const live = html.replace("12K views", "693 watching").replace("3 days ago", "Live");
  assert.equal(parseYouTubeSubscriptions(live)[0].published, "Live");
});

test("YouTube detects logged-out, consent, malformed pages; empty subscriptions valid", () => {
  assert.throws(() => parseYouTubeSubscriptions('<script>ytcfg.set({"LOGGED_IN":false})</script>'), NotLoggedInError);
  assert.throws(() => parseYouTubeSubscriptions(page({}, { responseContext: { mainAppWebResponseContext: { loggedOut: true } } })), NotLoggedInError);
  for (const html of ["consent page", "ytInitialData = {bad}", "ytInitialData = {};"]) {
    assert.throws(() => parseYouTubeSubscriptions(html), /unavailable/);
  }
  assert.deepEqual(parseYouTubeSubscriptions(page({ items: [] })), []);
});

test("YouTube uses browser credentials and handles network/login/consent errors", async () => {
  const original = globalThis.fetch;
  try {
    let request;
    globalThis.fetch = async (...args) => {
      request = args;
      return { ok: true, url: "https://www.youtube.com/feed/subscriptions", text: async () => page({ items: [video()] }) };
    };
    assert.equal((await fetchYouTube(10)).length, 1);
    assert.equal(request[0], "https://www.youtube.com/feed/subscriptions");
    assert.equal(request[1].credentials, "include");
    for (const status of [401, 403, 500]) {
      globalThis.fetch = async () => ({ ok: false, status });
      await assert.rejects(fetchYouTube(10), status === 500 ? /HTTP 500/ : NotLoggedInError);
    }
    globalThis.fetch = async () => ({ ok: true, url: "https://consent.youtube.com/" });
    await assert.rejects(fetchYouTube(10), /consent/);
  } finally { globalThis.fetch = original; }
});
