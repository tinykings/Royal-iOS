import test from "node:test";
import assert from "node:assert/strict";
import { CONFIG, fetchReddit, fetchSubscribedSubreddits, NotLoggedInError } from "./sources.js";

test("Reddit sort uses personalized Best and score-ranked Top with timeframe, and has no New", async () => {
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
    await assert.rejects(fetchReddit(3, { sort: "new" }), /Invalid Reddit sort/);
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
    assert.equal((await fetchReddit(100, { sort: "top" })).length, 5);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// A stand-in for Reddit's home listings: Top in pages of `after`, and Best. `fail` names
// requests ("top", "top:<after>", "best") to answer with an error.
function mockHome({ top, best = [], fail = [] }) {
  const requests = [];
  const post = ([name, subreddit, score]) => ({ data: {
    name, title: name, subreddit, score, created_utc: 1,
    permalink: `/r/${subreddit}/comments/${name}`, url: `https://example.com/${name}`,
  } });
  globalThis.fetch = async (url) => {
    const parsed = new URL(url);
    if (parsed.pathname.startsWith("/subreddits/mine/")) {
      return { ok: true, json: async () => ({ data: { children: [{ data: { display_name: "test" } }], after: null } }) };
    }
    requests.push(parsed);
    const after = parsed.searchParams.get("after");
    const request = parsed.pathname === "/best.json" ? "best" : after ? `top:${after}` : "top";
    if (fail.includes(request)) return { ok: false, status: 500 };
    const page = request === "best" ? { posts: best } : top[after ?? ""];
    return { ok: true, json: async () => ({ data: { children: page.posts.map(post), after: page.after ?? null } }) };
  };
  return requests;
}

test("Reddit mix reads on down Top, adds Best, and takes each subreddit's best post before any second", async () => {
  const originalFetch = globalThis.fetch;
  const requests = mockHome({
    top: {
      "": { posts: [["big1", "big", 900], ["big2", "big", 800], ["big3", "big", 700]], after: "p2" },
      p2: { posts: [["big4", "big", 600], ["mid1", "mid", 90], ["big5", "big", 500]], after: "p3" },
      p3: { posts: [["big6", "big", 400], ["mid2", "mid", 50]], after: null },
    },
    best: [["small1", "small", 7], ["mid1", "mid", 90], ["small2", "small", 3]],
  });
  try {
    const posts = await fetchReddit(100, { sort: "mix", timeframe: "day" });
    assert.deepEqual(posts.map((post) => post.id),
      ["big1", "mid1", "small1", "big2", "mid2", "small2", "big3", "big4", "big5"]);
    assert.deepEqual(requests.map((url) => `${url.pathname} ${url.searchParams.get("after") ?? ""}`).sort(),
      ["/best.json ", "/top.json ", "/top.json p2", "/top.json p3"]);
    assert.ok(requests.every((url) => url.pathname === "/best.json" || url.searchParams.get("t") === "day"));
    // The limit cuts the spread list, so it's the busiest subreddit's extra posts that go.
    assert.deepEqual((await fetchReddit(4, { sort: "mix" })).map((post) => post.id), ["big1", "mid1", "small1", "big2"]);
    await assert.rejects(fetchReddit(100, { sort: "mix", subreddit: "swift" }), /Invalid Reddit sort/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("Reddit mix stops at its page limit, and keeps what loaded when a later page or Best fails", async () => {
  const originalFetch = globalThis.fetch;
  const endless = (after) => ({ posts: [[`post${after}`, `sub${after}`, 10]], after: String(Number(after) + 1) });
  const top = Object.fromEntries(["", "1", "2", "3", "4", "5"].map((after) => [after, endless(after || "0")]));
  try {
    let requests = mockHome({ top });
    assert.equal((await fetchReddit(100, { sort: "mix" })).length, CONFIG.redditMixTopPages);
    assert.equal(requests.filter((url) => url.pathname === "/top.json").length, CONFIG.redditMixTopPages);

    requests = mockHome({ top, best: [["liked", "quiet", 2]], fail: ["top:2"] });
    assert.deepEqual((await fetchReddit(100, { sort: "mix" })).map((post) => post.id), ["post0", "post1", "liked"]);

    mockHome({ top, fail: ["best"] });
    assert.equal((await fetchReddit(100, { sort: "mix" })).length, CONFIG.redditMixTopPages);

    mockHome({ top, best: [["liked", "quiet", 2]], fail: ["top"] });
    await assert.rejects(fetchReddit(100, { sort: "mix" }), /HTTP 500/);
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
