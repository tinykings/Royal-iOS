// Fetching and normalizing posts from Reddit, Hacker News, and YouTube.
// Every post is normalized to:
//   { source, id, title, url, commentsUrl, score, comments, created, label, image?, imageAspect? }
// markSeen() adds `seen: true|false`.

export const CONFIG = {
  totalItems: 100,
  redditTimeWindow: "day", // hour | day | week | month | year | all
  maxPerSubreddit: 5, // keeps huge subs from crowding out small ones
  seenHistory: 2000, // post ids remembered per source for marking repeats
};

const REDDIT = "https://www.reddit.com";
const HN = "https://hacker-news.firebaseio.com/v0";
const YOUTUBE = "https://www.youtube.com";

export class NotLoggedInError extends Error {}

async function getJson(url) {
  const res = await fetch(url, { credentials: "include" });
  if (res.status === 401 || res.status === 403) {
    throw new NotLoggedInError(`${res.status} from ${new URL(url).host}`);
  }
  if (!res.ok) throw new Error(`HTTP ${res.status} from ${url}`);
  return res.json();
}

async function getSubscriptions() {
  const subs = [];
  let after = null;
  do {
    const params = new URLSearchParams({ limit: "100", raw_json: "1" });
    if (after) params.set("after", after);
    const data = await getJson(`${REDDIT}/subreddits/mine/subscriber.json?${params}`);
    for (const child of data.data.children) subs.push(child.data.display_name);
    after = data.data.after;
  } while (after && subs.length < 1000);

  // Reddit answers anonymous requests with an empty listing rather than an error.
  if (subs.length === 0) throw new NotLoggedInError("no subscriptions returned");
  return subs;
}

function imageUrl(value) {
  if (typeof value !== "string") return null;
  const decoded = value.replace(/&amp;/g, "&");
  try {
    const url = new URL(decoded);
    return url.protocol === "https:" ? url.href : null;
  } catch {
    return null;
  }
}

// Width over height, when Reddit reports both, so the app can size an image before it loads.
function aspect(width, height) {
  return width > 0 && height > 0 ? width / height : null;
}

function sizedImage(url, width, height) {
  const href = imageUrl(url);
  return href ? { url: href, aspect: aspect(width, height) } : null;
}

function redditImage(post) {
  const preview = post.preview?.images?.[0];
  const galleryId = post.gallery_data?.items?.[0]?.media_id;
  const gallery = post.media_metadata?.[galleryId];
  const resolutions = preview?.resolutions ?? gallery?.p ?? [];
  const sized = resolutions.find((image) => image.width >= 640 || image.x >= 640)
    ?? resolutions[resolutions.length - 1];
  const direct = post.url_overridden_by_dest ?? post.url;
  return sizedImage(sized?.url ?? sized?.u, sized?.width ?? sized?.x, sized?.height ?? sized?.y)
    ?? sizedImage(preview?.source?.url, preview?.source?.width, preview?.source?.height)
    ?? sizedImage(gallery?.s?.u, gallery?.s?.x, gallery?.s?.y)
    ?? (/\.(?:jpe?g|png|gif|webp)(?:[?#]|$)/i.test(direct ?? "") ? sizedImage(direct) : null)
    ?? (post.crosspost_parent_list?.[0] ? redditImage(post.crosspost_parent_list[0]) : null)
    ?? sizedImage(post.thumbnail, post.thumbnail_width, post.thumbnail_height);
}

export async function fetchReddit(limit, { sort = "best", timeframe = CONFIG.redditTimeWindow } = {}) {
  if (!["best", "top", "new"].includes(sort)) throw new Error("Invalid Reddit sort");
  if (!["hour", "day", "week", "month", "year", "all"].includes(timeframe)) throw new Error("Invalid Reddit timeframe");
  // Confirms login: anonymous sessions get an empty subscription list.
  await getSubscriptions();

  const params = new URLSearchParams({ limit: "100", raw_json: "1" });
  if (sort === "top") params.set("t", timeframe);
  // Logged-in home listings cover subscriptions. Reddit now redirects combined
  // r/a+b+c listings to its home page instead of returning JSON.
  const listing = await getJson(`${REDDIT}/${sort}.json?${params}`);

  const posts = listing.data.children
    .map((c) => c.data)
    .filter((p) => !p.stickied && !p.over_18);
  if (sort === "top") posts.sort((a, b) => b.score - a.score);
  if (sort === "new") posts.sort((a, b) => b.created_utc - a.created_utc);

  const perSub = new Map();
  const picked = [];
  for (const p of posts) {
    const n = perSub.get(p.subreddit) ?? 0;
    if (n >= CONFIG.maxPerSubreddit) continue;
    perSub.set(p.subreddit, n + 1);
    const commentsUrl = REDDIT + p.permalink;
    const image = redditImage(p);
    picked.push({
      source: "reddit",
      id: p.name,
      title: p.title,
      url: p.is_self ? commentsUrl : p.url,
      commentsUrl,
      score: p.score,
      comments: p.num_comments,
      created: p.created_utc,
      label: `r/${p.subreddit}`,
      image: image?.url ?? null,
      imageAspect: image?.aspect ?? null,
    });
    if (picked.length >= limit) break;
  }
  return picked;
}

async function hackerNewsIds(list) {
  if (!["top", "new"].includes(list)) throw new Error("Invalid Hacker News list");
  return getJson(`${HN}/${list}stories.json`);
}

// Fetches stories by id, dropping dead, deleted, and untitled ones.
async function hackerNewsItems(ids) {
  const items = await Promise.all(ids.map((id) => getJson(`${HN}/item/${id}.json`).catch(() => null)));
  return items
    .filter((it) => it && !it.dead && !it.deleted && it.title)
    .map((it) => {
      const commentsUrl = `https://news.ycombinator.com/item?id=${it.id}`;
      return {
        source: "hn",
        id: `hn_${it.id}`,
        title: it.title,
        url: it.url || commentsUrl,
        commentsUrl,
        score: it.score ?? 0,
        comments: it.descendants ?? 0,
        created: it.time,
        label: "Hacker News",
      };
    });
}

export async function fetchHackerNews(limit, { list = "top" } = {}) {
  const ids = await hackerNewsIds(list);
  // A few extra ids make up for stories that turn out dead or deleted.
  return (await hackerNewsItems(ids.slice(0, limit + 10))).slice(0, limit);
}

// One page of stories, so callers can show the first page fast and fetch more on
// demand. `next` is the offset of the following page, or null after the last one.
export async function fetchHackerNewsPage(count, { list = "top", offset = 0 } = {}) {
  const ids = await hackerNewsIds(list);
  const end = offset + count;
  return { posts: await hackerNewsItems(ids.slice(offset, end)), next: end < ids.length ? end : null };
}

// YouTube only shows ages like "3 hours ago", rounded down. Returns the latest time
// (epoch seconds) the video could have been published, or null when there's no age.
const AGE_UNITS = { second: 1, minute: 60, hour: 3600, day: 86400, week: 604800, month: 2592000, year: 31536000 };
export function youTubePublishedAt(published, now = Date.now() / 1000) {
  const match = /^(?:Streamed |Premiered )?(\d+) (second|minute|hour|day|week|month|year)s? ago$/i.exec(published ?? "");
  return match ? now - Number(match[1]) * AGE_UNITS[match[2].toLowerCase()] : null;
}

// YouTube exposes subscriptions in page data, not a supported public session API.
// Parse JSON only: never execute scripts from the fetched page.
export function parseYouTubeSubscriptions(html, limit = CONFIG.totalItems) {
  if (/"LOGGED_IN"\s*:\s*false/.test(html)) throw new NotLoggedInError("YouTube session is logged out");
  const assignment = /(?:var\s+ytInitialData|window\["ytInitialData"\]|ytInitialData)\s*=\s*/g;
  let data;
  for (const match of html.matchAll(assignment)) {
    const start = match.index + match[0].length;
    if (html[start] !== "{") continue;
    let depth = 0, quoted = false, escaped = false;
    for (let i = start; i < html.length; i++) {
      const c = html[i];
      if (quoted) {
        if (escaped) escaped = false;
        else if (c === "\\") escaped = true;
        else if (c === '"') quoted = false;
      } else if (c === '"') quoted = true;
      else if (c === "{") depth++;
      else if (c === "}" && --depth === 0) {
        try { data = JSON.parse(html.slice(start, i + 1)); } catch { /* Try next assignment. */ }
        break;
      }
    }
    if (data) break;
  }
  if (!data) throw new Error("YouTube page data unavailable. Open YouTube, finish any consent prompts, then refresh.");
  if (data.responseContext?.mainAppWebResponseContext?.loggedOut) {
    throw new NotLoggedInError("YouTube session is logged out");
  }
  const text = (value) => value?.simpleText ?? value?.runs?.map((r) => r.text).join("") ?? value?.content ?? "";
  // Lockups list views and age as unlabeled parts, e.g. "12K views", "3 days ago";
  // live streams show "693 watching" instead of an age.
  const lockupAge = (metadata) => {
    const parts = metadata?.metadata?.contentMetadataViewModel?.metadataRows
      ?.flatMap((row) => row.metadataParts ?? []).map((part) => text(part.text)) ?? [];
    if (parts.some((part) => /\bwatching\b/i.test(part))) return "Live";
    return parts.find((part) => /\bago$|^(Streamed|Premiered|Scheduled for)\b/i.test(part)) ?? "";
  };
  const posts = [], ids = new Set();
  function visit(node) {
    if (!node || typeof node !== "object" || posts.length >= limit) return;
    // Ranked carousels ("Most relevant"), Shorts, and other rich shelves are
    // supplemental sections, not the chronological subscription upload list.
    if (node.richSectionRenderer || node.richShelfRenderer || node.reelShelfRenderer
      || node.horizontalListRenderer) return;
    // In-feed ads can wrap ordinary video renderers for channels the user doesn't follow.
    if (node.adSlotRenderer || node.inFeedAdLayoutRenderer || node.promotedVideoRenderer
      || node.adSlotMetadata || node.feedAdMetadataViewModel) return;
    const section = node.shelfRenderer ?? node.itemSectionRenderer;
    if (section) {
      const heading = text(section.title) || text(section.header?.itemSectionHeaderRenderer?.title);
      if (/most relev[ae]nt|recommended|for you/i.test(heading)) return;
    }
    const video = node.videoRenderer ?? node.gridVideoRenderer;
    const lockup = node.lockupViewModel;
    const id = video?.videoId ?? (lockup?.contentType === "LOCKUP_CONTENT_TYPE_VIDEO" ? lockup.contentId : null);
    if (typeof id === "string" && /^[\w-]{11}$/.test(id) && !ids.has(id)) {
      const metadata = lockup?.metadata?.lockupMetadataViewModel;
      const title = text(video?.title ?? metadata?.title);
      if (title) {
        ids.add(id);
        const url = `${YOUTUBE}/watch?v=${id}`;
        posts.push({
          source: "youtube", id: `yt_${id}`, videoId: id, title, url, commentsUrl: url,
          label: text(video?.ownerText ?? video?.shortBylineText ?? video?.longBylineText)
            || text(metadata?.metadata?.contentMetadataViewModel?.metadataRows?.[0]?.metadataParts?.[0]?.text)
            || "YouTube",
          published: text(video?.publishedTimeText) || lockupAge(metadata),
          image: `https://i.ytimg.com/vi/${id}/maxresdefault.jpg`,
        });
      }
    }
    for (const value of Object.values(node)) visit(value);
  }
  const tabs = data.contents?.twoColumnBrowseResultsRenderer?.tabs;
  const selected = tabs?.find((tab) => tab.tabRenderer?.selected)?.tabRenderer;
  if (!data.contents) throw new Error("YouTube subscriptions unavailable. Check login and consent on YouTube.");
  visit(selected?.content ?? data.contents);
  const now = Date.now() / 1000;
  for (const post of posts) post.publishedAt = youTubePublishedAt(post.published, now);
  return posts;
}

export async function fetchYouTube(limit) {
  const response = await fetch(`${YOUTUBE}/feed/subscriptions`, { credentials: "include" });
  if (response.status === 401 || response.status === 403) throw new NotLoggedInError("YouTube login required");
  if (!response.ok) throw new Error(`YouTube HTTP ${response.status}`);
  if (response.url && new URL(response.url).hostname !== "www.youtube.com") {
    throw new Error("Open YouTube and finish login or consent, then refresh.");
  }
  return parseYouTubeSubscriptions(await response.text(), limit);
}

// Alternates reddit, hn, reddit, hn... If one source runs short, the other fills the rest.
// Links that appear on both sites are kept once.
export function interleave(reddit, hn, total) {
  const out = [];
  const seenUrls = new Set();
  let r = 0;
  let h = 0;
  let turn = "reddit";
  while (out.length < total && (r < reddit.length || h < hn.length)) {
    const takeReddit = (turn === "reddit" && r < reddit.length) || h >= hn.length;
    const post = takeReddit ? reddit[r++] : hn[h++];
    if (seenUrls.has(post.url)) continue; // same source tries again with its next post
    seenUrls.add(post.url);
    turn = takeReddit ? "hn" : "reddit";
    out.push(post);
  }
  return out;
}

// Flags posts already shown by an earlier fetch, then records this fetch's ids.
// `seen` maps each source to its ids, oldest first, capped at `max` per source.
export function markSeen(posts, seen = {}, max = CONFIG.seenHistory) {
  const updated = {};
  for (const [source, ids] of Object.entries(seen ?? {})) {
    if (Array.isArray(ids)) updated[source] = ids;
  }
  const previous = Object.fromEntries(Object.entries(updated).map(([source, ids]) => [source, new Set(ids)]));
  const marked = posts.map((p) => ({ ...p, seen: previous[p.source]?.has(p.id) ?? false }));
  for (const source of new Set(posts.map((p) => p.source))) {
    const current = posts.filter((p) => p.source === source).map((p) => p.id);
    const currentSet = new Set(current);
    updated[source] = [...(updated[source] ?? []).filter((id) => !currentSet.has(id)), ...current].slice(-max);
  }
  return { posts: marked, seen: updated };
}
