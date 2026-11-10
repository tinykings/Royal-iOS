// Royal's desktop feed state, kept in the worker: the All snapshot, what All has
// shown (seen), and saved posts. Pure functions over a plain JSON state so they
// can be stored, tested, and later synced. They mirror Royal/FeedStore.swift.

export const ALL_SOURCES = [
  // iOS FeedKey.combined: Reddit Top today, Hacker News Top, YouTube subscriptions.
  { source: "reddit", options: { sort: "top", timeframe: "day" } },
  { source: "hn", options: { list: "top" } },
  { source: "youtube", options: { feed: "subscriptions" } },
];
export const SEEN_LIMIT = 3000;

export function emptyState() {
  return {
    version: 1,
    // Replaced only by refreshAll; source tabs never touch it.
    all: { lists: { reddit: [], hn: [], youtube: [] }, errors: {}, refreshedAt: null, previousRefresh: null, previouslySeen: [], previousSources: [] },
    // Post ids All has shown, oldest first, capped like iOS's allFeedSeenIDs.
    seen: [],
    // Sources that had posts in some refresh (iOS allFeedSources).
    sources: [],
    hasMarkedRead: false,
    // postID -> { post, savedAt (ISO 8601), isSaved }. Unsaves stay as tombstones.
    saved: {},
  };
}

const httpURL = value => {
  try { const url = new URL(value); return ["https:", "http:"].includes(url.protocol) ? url.href : null; }
  catch { return null; }
};
const finite = value => (Number.isFinite(value) ? value : null);
const text = value => (typeof value === "string" ? value : null);

// The sources.js post shape (Royal's FeedPost), with types checked and links
// limited to http(s). Returns null for anything that can't be shown.
export function normalizePost(post) {
  if (!post || typeof post !== "object") return null;
  const url = httpURL(post.url);
  if (!["reddit", "hn", "youtube"].includes(post.source) || !url || typeof post.title !== "string" ||
      typeof post.id !== "string" || !/^[\w-]{1,100}$/.test(post.id)) return null;
  return {
    source: post.source, id: post.id, title: post.title, url,
    commentsUrl: httpURL(post.commentsUrl) ?? url, label: text(post.label) ?? "",
    score: finite(post.score), comments: finite(post.comments), created: finite(post.created),
    image: httpURL(post.image), imageAspect: finite(post.imageAspect), videoId: text(post.videoId),
    published: text(post.published), publishedAt: finite(post.publishedAt),
    nsfw: typeof post.nsfw === "boolean" ? post.nsfw : null,
  };
}

// iOS FeedStore.posts(_:): alternate sources in order, keeping each link once.
export function interleave(lists) {
  const out = [], urls = new Set(), next = lists.map(() => 0);
  let progressed = true;
  while (progressed) {
    progressed = false;
    lists.forEach((list, i) => {
      while (next[i] < list.length) {
        const post = list[next[i]++];
        if (!urls.has(post.url)) { urls.add(post.url); out.push(post); progressed = true; return; }
      }
    });
  }
  return out;
}

export const allPosts = state => interleave(ALL_SOURCES.map(({ source }) => state.all.lists[source] ?? []));

function remember(seen, ids) {
  const set = new Set(ids);
  return [...seen.filter(id => !set.has(id)), ...ids].slice(-SEEN_LIMIT);
}

// Applies an explicit All refresh. `results` maps source -> { state, posts }.
// A source that failed keeps its earlier posts, like iOS. Then, like
// FeedStore.recordRefresh, the previous refresh's seen ids become the baseline
// for what's new.
export function applyAllRefresh(state, results, now = Date.now()) {
  const lists = {}, errors = {};
  for (const { source } of ALL_SOURCES) {
    const result = results[source];
    if (result?.state === "ok") lists[source] = result.posts.map(normalizePost).filter(Boolean);
    else {
      lists[source] = state.all.lists[source] ?? [];
      errors[source] = { state: result?.state ?? "error", message: result?.message ?? "Feed failed.", login: result?.login ?? null };
    }
  }
  const next = { ...state, all: { ...state.all, lists, errors } };
  const current = allPosts(next);
  next.all.previouslySeen = state.seen;
  next.all.previousRefresh = state.all.refreshedAt;
  next.all.previousSources = state.sources;
  next.all.refreshedAt = now;
  next.sources = [...new Set([...state.sources, ...current.map(post => post.source)])];
  next.seen = remember(state.seen, current.map(post => post.id));
  return next;
}

// FeedStore.markAllRead: everything All shows joins the earlier posts.
export function markAllRead(state, now = Date.now()) {
  const ids = allPosts(state).map(post => post.id);
  return {
    ...state,
    all: { ...state.all, previouslySeen: [...new Set([...state.all.previouslySeen, ...ids])], previousRefresh: state.all.refreshedAt ?? now },
    seen: remember(state.seen, ids),
    hasMarkedRead: true,
  };
}

// FeedStore.splitByRefresh. Reddit and HN rank posts, so any unseen post is new.
// YouTube is chronological: new videos are those above the newest seen one, or,
// when none was seen, those published after the previous refresh.
export function splitByRefresh(state) {
  const posts = allPosts(state);
  const { previousRefresh, previouslySeen, previousSources } = state.all;
  if (!previousRefresh || previouslySeen.length === 0) return { new: posts, seen: [] };
  const seen = new Set(previouslySeen), sources = new Set(previousSources);
  const videos = state.all.lists.youtube ?? [];
  const newestSeenVideo = videos.findIndex(post => seen.has(post.id));
  const videosAboveSeen = new Set(videos.slice(0, Math.max(newestSeenVideo, 0)).map(post => post.id));
  const isNew = post => {
    if (seen.has(post.id) || !sources.has(post.source)) return false;
    if (post.source === "youtube") {
      if (newestSeenVideo >= 0) return videosAboveSeen.has(post.id);
      if (post.publishedAt != null) return post.publishedAt > previousRefresh / 1000;
    }
    return true;
  };
  return { new: posts.filter(isNew), seen: posts.filter(post => !isNew(post)) };
}

export function setSaved(state, post, isSaved, now = new Date()) {
  const normalized = normalizePost(post);
  if (!normalized) throw new Error("Invalid post.");
  const existing = state.saved[normalized.id];
  if (Boolean(existing?.isSaved) === isSaved) return state;
  return {
    ...state,
    saved: { ...state.saved, [normalized.id]: { post: isSaved ? normalized : existing?.post ?? normalized, savedAt: now.toISOString(), isSaved } },
  };
}

// Newest first, tombstones left out.
export const savedPosts = state => Object.values(state.saved)
  .filter(entry => entry.isSaved)
  .sort((a, b) => b.savedAt.localeCompare(a.savedAt))
  .map(entry => entry.post);
