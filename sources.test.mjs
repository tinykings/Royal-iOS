import test from "node:test";
import assert from "node:assert/strict";
import { fetchHackerNews, fetchHackerNewsPage, fetchReddit, markSeen } from "./sources.js";

test("Reddit sort uses personalized Best, score-ranked Top with timeframe, and chronological New", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(new URL(url));
    return {
      ok: true,
      json: async () => url.includes("/subreddits/mine/")
        ? { data: { children: [{ data: { display_name: "test" } }], after: null } }
        : { data: { children: [
          { name: "first", score: 5, created_utc: 10 },
          { name: "popular", score: 100, created_utc: 20 },
          { name: "newest", score: 1, created_utc: 30 },
        ].map((post) => ({ data: {
          ...post, subreddit: "test", permalink: `/r/test/comments/${post.name}`,
          url: `https://example.com/${post.name}`,
        } })) } },
    };
  };
  try {
    assert.deepEqual((await fetchReddit(3)).map((post) => post.id), ["first", "popular", "newest"]);
    assert.equal(requests.at(-1).pathname, "/best.json");
    assert.equal(requests.at(-1).searchParams.has("t"), false);
    for (const timeframe of ["hour", "day", "week", "month", "year", "all"]) {
      assert.deepEqual((await fetchReddit(3, { sort: "top", timeframe })).map((post) => post.id), ["popular", "first", "newest"]);
      assert.equal(requests.at(-1).pathname, "/top.json");
      assert.equal(requests.at(-1).searchParams.get("t"), timeframe);
    }
    assert.deepEqual((await fetchReddit(3, { sort: "new" })).map((post) => post.id), ["newest", "popular", "first"]);
    assert.equal(requests.at(-1).pathname, "/new.json");
    assert.equal(requests.at(-1).searchParams.has("t"), false);
    await assert.rejects(fetchReddit(3, { sort: "invalid" }), /Invalid Reddit sort/);
    await assert.rejects(fetchReddit(3, { sort: "top", timeframe: "invalid" }), /Invalid Reddit timeframe/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Reddit images: previews, galleries, crossposts, fallbacks, missing images, and aspect ratios", async () => {
  const cases = [
    [{ preview: { images: [{ resolutions: [
      { width: 108, url: "https://preview.redd.it/small.jpg" },
      { width: 320, url: "https://preview.redd.it/medium.jpg" },
      { width: 640, height: 480, url: "https://preview.redd.it/image.jpg?a=1&amp;b=2" },
      { width: 960, url: "https://preview.redd.it/large.jpg" },
    ] }] } }, "https://preview.redd.it/image.jpg?a=1&b=2"],
    [{ preview: { images: [{ source: { url: "https://i.redd.it/source.jpg" } }] } }, "https://i.redd.it/source.jpg"],
    [{ gallery_data: { items: [{ media_id: "first" }] }, media_metadata: {
      first: { s: { u: "https://i.redd.it/gallery.png" } },
    } }, "https://i.redd.it/gallery.png"],
    [{ crosspost_parent_list: [{ thumbnail: "https://b.thumbs.redditmedia.com/image.jpg" }] }, "https://b.thumbs.redditmedia.com/image.jpg"],
    [{ url: "https://i.redd.it/direct.webp" }, "https://i.redd.it/direct.webp"],
    [{ thumbnail: "https://b.thumbs.redditmedia.com/thumb.jpg" }, "https://b.thumbs.redditmedia.com/thumb.jpg"],
    [{ thumbnail: "self" }, null],
    [{ thumbnail: "nsfw" }, null],
    [{ thumbnail: "javascript:alert(1)" }, null],
    [{}, null],
  ];
  const originalFetch = globalThis.fetch;
  try {
    for (const [fields, expected] of cases) {
      globalThis.fetch = async (url) => ({
        ok: true,
        json: async () => url.includes("/subreddits/mine/")
          ? { data: { children: [{ data: { display_name: "test" } }], after: null } }
          : { data: { children: [{ data: {
            name: "t3_test", subreddit: "test", permalink: "/r/test/comments/test",
            url: "https://example.com/post", score: 10, ...fields,
          } }] } },
      });
      const [post] = await fetchReddit(1);
      assert.equal(post.image, expected);
    }
    globalThis.fetch = async (url) => ({
      ok: true,
      json: async () => url.includes("/subreddits/mine/")
        ? { data: { children: [{ data: { display_name: "test" } }], after: null } }
        : { data: { children: [
          { data: { name: "t3_a", subreddit: "a", permalink: "/r/a", ...cases[0][0] } },
          { data: { name: "t3_b", subreddit: "b", permalink: "/r/b", media_metadata: { m: { s: { u: "https://i.redd.it/g.png", x: 500, y: 1000 } } },
            gallery_data: { items: [{ media_id: "m" }] } } },
          { data: { name: "t3_c", subreddit: "c", permalink: "/r/c", url: "https://i.redd.it/direct.webp" } },
        ] } },
    });
    const [preview, gallery, direct] = await fetchReddit(3);
    assert.equal(preview.imageAspect, 640 / 480);
    assert.equal(gallery.imageAspect, 0.5);
    assert.equal(direct.imageAspect, null);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("markSeen flags repeats per source and keeps a capped history", () => {
  const post = (source, id) => ({ source, id });
  const first = markSeen([post("reddit", "a"), post("hn", "a")], undefined, 3);
  assert.deepEqual(first.posts.map((p) => p.seen), [false, false]);
  const second = markSeen([post("reddit", "b"), post("reddit", "a"), post("hn", "c")], first.seen, 3);
  assert.deepEqual(second.posts.map((p) => p.seen), [false, true, false]);
  assert.deepEqual(second.seen, { reddit: ["b", "a"], hn: ["a", "c"] });
  const third = markSeen([post("reddit", "c"), post("reddit", "d")], second.seen, 3);
  assert.deepEqual(third.seen.reddit, ["a", "c", "d"]);
  assert.deepEqual(third.seen.hn, ["a", "c"]);
  assert.deepEqual(markSeen([post("hn", "x")], { hn: "corrupt" }).posts[0].seen, false);
});

test("Hacker News list picks top or new stories", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(new URL(url).pathname);
    return {
      ok: true,
      json: async () => url.includes("stories.json")
        ? [1]
        : { id: 1, title: "Story", url: "https://example.com/", time: 0 },
    };
  };
  try {
    await fetchHackerNews(1);
    assert.equal(requests[0], "/v0/topstories.json");
    requests.length = 0;
    await fetchHackerNews(1, { list: "new" });
    assert.equal(requests[0], "/v0/newstories.json");
    await assert.rejects(fetchHackerNews(1, { list: "best" }), /Invalid Hacker News list/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Hacker News pages walk the story list and report the next offset", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => ({
    ok: true,
    json: async () => {
      if (url.includes("stories.json")) return [1, 2, 3, 4, 5];
      const id = Number(new URL(url).pathname.match(/(\d+)\.json$/)[1]);
      return id === 2 ? { id, dead: true } : { id, title: `Story ${id}`, time: 0 };
    },
  });
  try {
    const first = await fetchHackerNewsPage(3);
    assert.deepEqual(first.posts.map((p) => p.id), ["hn_1", "hn_3"]);
    assert.equal(first.next, 3);
    const last = await fetchHackerNewsPage(3, { offset: first.next });
    assert.deepEqual(last.posts.map((p) => p.id), ["hn_4", "hn_5"]);
    assert.equal(last.next, null);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
