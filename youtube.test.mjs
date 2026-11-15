import test from "node:test";
import assert from "node:assert/strict";
import { fetchYouTube, parseYouTubeFeed, NotLoggedInError, youTubePublishedAt } from "./sources.js";

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
  const posts = parseYouTubeFeed(html);
  assert.equal(posts.length, 2);
  assert.equal(posts[0].source, "youtube");
  assert.equal(posts[0].id, "yt_abcdefghijk");
  assert.equal(posts[0].title, 'Video "title" } \\ test');
  assert.equal(posts[0].label, "Channel");
  assert.equal(posts[0].published, "2 hours ago");
  assert.equal(posts[0].image, "https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg");
  assert.equal(posts[0].url, "https://www.youtube.com/watch?v=abcdefghijk");
  assert.equal(parseYouTubeFeed(html, 1).length, 1);
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
  assert.deepEqual(parseYouTubeFeed(html).map((p) => p.videoId), ["abcdefghijk", "12345678901"]);
  assert.equal(parseYouTubeFeed(html, 1)[0].videoId, "abcdefghijk");
});

test("YouTube skips in-feed ads that wrap videos from unsubscribed channels", () => {
  const html = page({ richGridRenderer: { contents: [
    { richItemRenderer: { content: { adSlotRenderer: { fulfillmentContent: { fulfilledLayout: {
      inFeedAdLayoutRenderer: { renderingContent: video("advideo0001") },
    } } } } } },
    { richItemRenderer: { content: { inFeedAdLayoutRenderer: { renderingContent: video("advideo0002") } } } },
    { richItemRenderer: { content: video() } },
  ] } });
  assert.deepEqual(parseYouTubeFeed(html).map((p) => p.videoId), ["abcdefghijk"]);
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
  assert.equal(parseYouTubeFeed(html)[0].title, "New layout");
  assert.equal(parseYouTubeFeed(html)[0].label, "Creator");
  assert.equal(parseYouTubeFeed(html)[0].published, "3 days ago");
  const live = html.replace("12K views", "693 watching").replace("3 days ago", "Live");
  assert.equal(parseYouTubeFeed(live)[0].published, "Live");
});

test("YouTube detects logged-out, consent, malformed pages; empty subscriptions valid", () => {
  assert.throws(() => parseYouTubeFeed('<script>ytcfg.set({"LOGGED_IN":false})</script>'), NotLoggedInError);
  assert.throws(() => parseYouTubeFeed(page({}, { responseContext: { mainAppWebResponseContext: { loggedOut: true } } })), NotLoggedInError);
  for (const html of ["consent page", "ytInitialData = {bad}", "ytInitialData = {};"]) {
    assert.throws(() => parseYouTubeFeed(html), /unavailable/);
  }
  assert.deepEqual(parseYouTubeFeed(page({ items: [] })), []);
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

test("YouTube's Home feed loads the home page, keeping its videos and dropping shelves and ads", async () => {
  const original = globalThis.fetch;
  try {
    let requested;
    globalThis.fetch = async (url) => {
      requested = url;
      return { ok: true, url, text: async () => page({ twoColumnBrowseResultsRenderer: { tabs: [{ tabRenderer: {
        selected: true,
        content: { richGridRenderer: { contents: [
          { richItemRenderer: { content: video() } },
          { richSectionRenderer: { content: { richShelfRenderer: { contents: [video("shortsvideo")] } } } },
          { richItemRenderer: { content: { adSlotRenderer: { renderingContent: video("advideo0001") } } } },
          { richItemRenderer: { content: video("12345678901") } },
        ] } },
      } }] } }) };
    };
    const posts = await fetchYouTube(100, { feed: "home" });
    assert.equal(requested, "https://www.youtube.com/");
    assert.deepEqual(posts.map((p) => p.videoId), ["abcdefghijk", "12345678901"]);
    assert.equal((await fetchYouTube(1, { feed: "home" })).length, 1);
    await assert.rejects(fetchYouTube(10, { feed: "constructor" }), /Invalid YouTube feed/);
  } finally { globalThis.fetch = original; }
});

test("YouTube ages become the latest possible publish time", () => {
  assert.equal(youTubePublishedAt("2 hours ago", 10000), 10000 - 7200);
  assert.equal(youTubePublishedAt("1 day ago", 100000), 100000 - 86400);
  assert.equal(youTubePublishedAt("Streamed 5 minutes ago", 1000), 700);
  assert.equal(youTubePublishedAt("23h ago", 100000), 100000 - 82800);
  assert.equal(youTubePublishedAt("5m ago", 1000), 700);
  assert.equal(youTubePublishedAt("2mo ago", 1e8), 1e8 - 2 * 2592000);
  assert.equal(youTubePublishedAt("1w ago", 1e6), 1e6 - 604800);
  assert.equal(youTubePublishedAt("Live", 1000), null);
  assert.equal(youTubePublishedAt("", 1000), null);
  const html = page({ items: [video()] });
  const before = Date.now() / 1000;
  const at = parseYouTubeFeed(html)[0].publishedAt;
  assert.ok(at >= before - 7200 && at <= Date.now() / 1000 - 7200);
});

test("YouTube keeps the channel each video is from", () => {
  const channel = "UC" + "a".repeat(22);
  const html = page({ items: [
    { videoRenderer: { ...video().videoRenderer, ownerText: { runs: [{
      text: "Channel", navigationEndpoint: { browseEndpoint: { browseId: channel } },
    }] } } },
    { lockupViewModel: {
      contentId: "12345678901", contentType: "LOCKUP_CONTENT_TYPE_VIDEO",
      metadata: { lockupMetadataViewModel: {
        title: { content: "Lockup" },
        image: { decoratedAvatarViewModel: { rendererContext: { commandContext: { onTap: {
          innertubeCommand: { browseEndpoint: { browseId: "FEwhat_to_watch" } },
        } } } } },
        metadata: { contentMetadataViewModel: { metadataRows: [{ metadataParts: [{
          text: { content: "Other", commandRuns: [{ onTap: { innertubeCommand: {
            browseEndpoint: { browseId: "UC" + "b".repeat(22) },
          } } }] },
        }] }] } },
      } },
    } },
    video("noChannel01"),
  ] });
  assert.deepEqual(parseYouTubeFeed(html).map((p) => p.channelId), [channel, "UC" + "b".repeat(22), undefined]);
});

test("YouTube subscriptions load further pages to the limit, signed for the page's session", async () => {
  const original = globalThis.fetch;
  const more = (token) => ({ continuationItemRenderer: { continuationEndpoint: { continuationCommand: { token } } } });
  const ytcfg = '<script>ytcfg.set({"INNERTUBE_CLIENT_VERSION":"2.20261110.01.00","USER_SESSION_ID":"123",'
    + '"SESSION_INDEX":0,"VISITOR_DATA":"Cgt2aXNpdG9y%3D%3D"})</script>';
  try {
    const requests = [];
    const pages = {
      first: [{ richItemRenderer: { content: video("video000001") } }, more("second")],
      second: [{ richItemRenderer: { content: video("video000002") } }, { richItemRenderer: { content: video("video000001") } }, more("again")],
      again: [more("again")],
    };
    globalThis.fetch = async (url, init = {}) => {
      requests.push([url, init]);
      if (init.method !== "POST") {
        return { ok: true, url, text: async () => ytcfg + page({ richGridRenderer: { contents: [
          { richItemRenderer: { content: video("video000000") } }, more("first"),
        ] } }) };
      }
      const { continuation } = JSON.parse(init.body);
      return { ok: true, text: async () => JSON.stringify({ onResponseReceivedActions: [
        { appendContinuationItemsAction: { continuationItems: pages[continuation] ?? [] } },
      ] }) };
    };
    const posts = await fetchYouTube(3);
    assert.deepEqual(posts.map((p) => p.videoId), ["video000000", "video000001", "video000002"]);
    assert.equal(requests.length, 3);
    const [url, init] = requests[1];
    assert.equal(url, "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false");
    assert.equal(init.userSession, "123");
    assert.equal(init.headers["X-YouTube-Client-Version"], "2.20261110.01.00");
    assert.equal(init.headers["X-Goog-Visitor-Id"], "Cgt2aXNpdG9y%3D%3D");
    assert.equal(JSON.parse(init.body).continuation, "first");
    assert.equal(typeof posts[2].publishedAt, "number");

    // Stops once the limit's reached or after a few pages, and keeps what loaded if a page fails.
    requests.length = 0;
    assert.equal((await fetchYouTube(1)).length, 1);
    assert.equal(requests.length, 1);
    requests.length = 0;
    assert.equal((await fetchYouTube(100)).length, 3);
    assert.equal(requests.length, 5);
    globalThis.fetch = async (url, init = {}) => init.method === "POST" ? { ok: false, status: 500 }
      : { ok: true, url, text: async () => page({ items: [video(), more("first")] }) };
    assert.equal((await fetchYouTube(100)).length, 1);
    // Home doesn't page.
    requests.length = 0;
    globalThis.fetch = async (url, init = {}) => { requests.push(init); return { ok: true, url, text: async () => page({ items: [video(), more("first")] }) }; };
    await fetchYouTube(100, { feed: "home" });
    assert.equal(requests.length, 1);
  } finally { globalThis.fetch = original; }
});
