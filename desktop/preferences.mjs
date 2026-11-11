// Choices made in the Settings tab, matching iOS Settings (Royal/Preferences.swift).
// Kept in chrome.storage.local under one key, for this browser only (they don't sync).
export const PREFERENCES_KEY = "royalPreferences";

export const DEFAULT_PREFERENCES = Object.freeze({
  redditLayout: "card",     // "card" | "row" (iOS: Cards | List)
  youtubeLayout: "card",
  redditOpen: "link",       // "link" | "comments": what a click on a post opens
  hnOpen: "link",
  youtubePlayback: "inApp", // "inApp" (the docked player) | "browser" (a new tab)
  listWhilePlaying: true,   // every feed switches to rows while the docked player plays
  blurNSFW: true,           // NSFW images stay blurred until clicked
});

const CHOICES = {
  redditLayout: ["card", "row"],
  youtubeLayout: ["card", "row"],
  redditOpen: ["link", "comments"],
  hnOpen: ["link", "comments"],
  youtubePlayback: ["inApp", "browser"],
  listWhilePlaying: [true, false],
  blurNSFW: [true, false],
};

// Stored values from an older or newer version fall back to the default one by one.
export function normalizePreferences(stored) {
  const preferences = { ...DEFAULT_PREFERENCES };
  if (stored && typeof stored === "object") {
    for (const [key, choices] of Object.entries(CHOICES)) {
      if (choices.includes(stored[key])) preferences[key] = stored[key];
    }
  }
  return preferences;
}

// Like iOS FeedListView.layout(for:): Saved mixes every source, so it stays in rows;
// so does everything while a video plays, if chosen; Hacker News is always rows, and
// so is any post with no image, so a text post's title looks like Hacker News's.
export function layoutFor(post, preferences, { saved = false, playing = false } = {}) {
  if (saved || !(post.image || post.videoId)) return "row";
  if (playing && preferences.listWhilePlaying && preferences.youtubePlayback === "inApp") return "row";
  if (post.source === "reddit") return preferences.redditLayout;
  if (post.source === "youtube") return preferences.youtubeLayout;
  return "row";
}

// Where a click on a Reddit or Hacker News post goes; the other is a link in its details.
// YouTube posts have no separate comments page.
export function opensComments(post, preferences) {
  if (post.source === "reddit") return preferences.redditOpen === "comments";
  if (post.source === "hn") return preferences.hnOpen === "comments";
  return false;
}

export async function loadPreferences(storage) {
  return normalizePreferences((await storage.get(PREFERENCES_KEY))[PREFERENCES_KEY]);
}

export async function savePreferences(storage, preferences) {
  const next = normalizePreferences(preferences);
  await storage.set({ [PREFERENCES_KEY]: next });
  return next;
}
