// Royal Saved's library state: the saved posts. Pure functions over a plain JSON
// state so they can be stored, tested, and synced. They mirror Royal/FeedStore.swift.

export function emptyState() {
  return {
    version: 1,
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
  if (!["reddit", "hn", "rss", "youtube"].includes(post.source) || !url || typeof post.title !== "string" ||
      typeof post.id !== "string" || !/^[\w-]{1,100}$/.test(post.id)) return null;
  return {
    source: post.source, id: post.id, title: post.title, url,
    commentsUrl: httpURL(post.commentsUrl) ?? url, label: text(post.label) ?? "",
    score: finite(post.score), comments: finite(post.comments), created: finite(post.created),
    image: httpURL(post.image), imageAspect: finite(post.imageAspect), videoId: text(post.videoId),
    published: text(post.published), publishedAt: finite(post.publishedAt),
    nsfw: typeof post.nsfw === "boolean" ? post.nsfw : null,
    // The video's channel, kept so a save round-tripped through here loses nothing iOS uses.
    ...(typeof post.channelId === "string" ? { channelId: post.channelId } : {}),
    // Imported from YouTube's Watch Later by iOS. Kept through an unsave here, so iOS
    // takes the video out of the playlist and doesn't import it again.
    ...(post.watchLater === true ? { watchLater: true } : {}),
  };
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
