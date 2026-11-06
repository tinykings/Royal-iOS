import test from "node:test";
import assert from "node:assert/strict";
import { fetchHackerNews, fetchHackerNewsPage, fetchReddit, fetchSubscribedSubreddits, NotLoggedInError } from "./sources.js";

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
    requests.length = 0;
    // New merges the listings Reddit allows, without repeating a post they share.
    assert.deepEqual((await fetchReddit(10, { sort: "new" })).map((post) => post.id), ["newest", "popular", "first"]);
    assert.deepEqual(requests.slice(1).map((r) => `${r.pathname} ${r.searchParams.get("t")}`),
      ["/top.json hour", "/top.json day", "/best.json null"]);
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

test("Reddit requires a followed subreddit instead of falling back to all of Reddit", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(new URL(url));
    return { ok: true, json: async () => ({ data: { children: [], after: null } }) };
  };
  try {
    await assert.rejects(fetchReddit(3), NotLoggedInError);
    assert.equal(requests.length, 1);
    assert.equal(requests[0].pathname, "/subreddits/mine/subscriber.json");
    assert.equal(requests[0].searchParams.get("limit"), "1");
  } finally {
    globalThis.fetch = originalFetch;
  }
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

test("A single subreddit uses its own listing, only sorts by Top, and isn't capped per subreddit", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(new URL(url));
    return {
      ok: true,
      json: async () => url.includes("/subreddits/mine/")
        ? { data: { children: [{ data: { display_name: "test" } }], after: null } }
        : { data: { children: Array.from({ length: 8 }, (_, i) => ({ data: {
          name: `p${i}`, title: `p${i}`, score: i, created_utc: i, subreddit: "swift",
          permalink: `/r/swift/comments/p${i}`, url: `https://example.com/p${i}`,
        } })) } },
    };
  };
  try {
    assert.equal((await fetchReddit(100, { sort: "top", timeframe: "day", subreddit: "swift" })).length, 8);
    assert.equal(requests.at(-1).pathname, "/r/swift/top.json");
    assert.equal(requests.at(-1).searchParams.get("t"), "day");
    await assert.rejects(fetchReddit(100, { sort: "top", subreddit: "../evil" }), /Invalid subreddit/);
    for (const sort of ["best", "hot", "new"]) {
      await assert.rejects(fetchReddit(100, { sort, subreddit: "swift" }), /Invalid Reddit sort/);
    }
    await assert.rejects(fetchReddit(100, { sort: "hot" }), /Invalid Reddit sort/);
    // Without a subreddit, the home listing keeps its cap.
    assert.equal((await fetchReddit(100, { sort: "new" })).length, 5);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Followed subreddits walk every page, sort A to Z, and skip people and NSFW", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  const pages = {
    "": { children: [{ display_name: "zig" }, { display_name: "u_someone", subreddit_type: "user" }], after: "t5_a" },
    t5_a: { children: [{ display_name: "Apple" }, { display_name: "nsfwsub", over18: true }, { display_name: "banana" }], after: null },
  };
  globalThis.fetch = async (url) => {
    const parsed = new URL(url);
    requests.push(parsed);
    const page = pages[parsed.searchParams.get("after") ?? ""];
    return { ok: true, json: async () => ({ data: { children: page.children.map((data) => ({ data })), after: page.after } }) };
  };
  try {
    assert.deepEqual(await fetchSubscribedSubreddits(), ["Apple", "banana", "zig"]);
    assert.equal(requests.length, 2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("NSFW posts and subreddits are left out unless asked for, and posts say which they are", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => ({
    ok: true,
    json: async () => url.includes("/subreddits/mine/")
      ? { data: { children: [{ data: { display_name: "safe" } }, { data: { display_name: "adult", over18: true } }], after: null } }
      : { data: { children: [
        { name: "clean", over_18: false },
        { name: "mature", over_18: true },
      ].map((post) => ({ data: { ...post, score: 1, created_utc: 1, subreddit: "test",
        permalink: `/r/test/comments/${post.name}`, url: `https://example.com/${post.name}` } })) } },
  });
  try {
    assert.deepEqual((await fetchReddit(10)).map((post) => post.id), ["clean"]);
    assert.deepEqual((await fetchReddit(10, { nsfw: true })).map((post) => [post.id, post.nsfw]),
      [["clean", false], ["mature", true]]);
    assert.deepEqual(await fetchSubscribedSubreddits(), ["safe"]);
    assert.deepEqual(await fetchSubscribedSubreddits({ nsfw: true }), ["adult", "safe"]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("A Reddit block page isn't reported as being logged out, but other refusals are", async () => {
  const originalFetch = globalThis.fetch;
  let body = "You've been blocked by network security.";
  globalThis.fetch = async () => ({ ok: false, status: 403, text: async () => body });
  try {
    await assert.rejects(fetchReddit(3), (error) => !(error instanceof NotLoggedInError) && /Reddit blocked/.test(error.message));
    body = "Forbidden";
    await assert.rejects(fetchReddit(3), NotLoggedInError);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
