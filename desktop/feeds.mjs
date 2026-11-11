// Worker-side feed operations. Runs the shared root sources.js (copied byte-for-byte
// to desktop/sources.js) with the browser's own cookies for each provider host.
// The page receives type-checked normalized posts (http(s) links only) or a short
// error, never cookies or raw pages.
import { fetchReddit, fetchSubscribedSubreddits, fetchHackerNews, fetchYouTube, NotLoggedInError } from "./sources.js";
import { normalizePost } from "./library.mjs";

export const FEED_LIMIT = 50;
// iOS shows Hacker News a page of 30 at a time (FeedSession.hackerNewsPageSize), so
// the desktop takes the same first page; more would count old stories as New.
export const HN_LIMIT = 30;

// One entry per source: the host it needs, where the user logs in, and the bounded
// options the page may choose. sources.js validates the same values again.
export const SOURCES = {
  reddit: {
    name: "Reddit", origin: "https://www.reddit.com/*", login: "https://www.reddit.com/login/",
    // `subreddit` is one followed subreddit's name, or "" for everything followed.
    options: { sort: ["best", "top"], timeframe: ["hour", "day", "week", "month", "year", "all"], subreddit: value => /^\w{0,50}$/.test(value) },
    fetch: options => fetchReddit(FEED_LIMIT, options),
  },
  hn: {
    name: "Hacker News", origin: "https://hacker-news.firebaseio.com/*", login: null,
    options: { list: ["top", "new"] },
    fetch: options => fetchHackerNews(HN_LIMIT, options),
  },
  youtube: {
    name: "YouTube", origin: "https://www.youtube.com/*", login: "https://www.youtube.com/",
    options: { feed: ["subscriptions", "home"] },
    fetch: options => fetchYouTube(FEED_LIMIT, options),
  },
};

function validOptions(source, options = {}) {
  const allowed = SOURCES[source].options, result = {};
  for (const [key, value] of Object.entries(options ?? {})) {
    const check = allowed[key];
    if (typeof value !== "string" || !(typeof check === "function" ? check(value) : check?.includes(value))) throw new Error(`Invalid ${SOURCES[source].name} option.`);
    result[key] = value;
  }
  return result;
}

function loginMessage(source, error) {
  if (source === "reddit" && /no followed subreddits/.test(error.message)) {
    return "Reddit returned no followed subreddits. Log into Reddit in this browser and follow at least one subreddit, then refresh.";
  }
  return `Log into ${SOURCES[source].name} in this browser (open ${new URL(SOURCES[source].login).host} in a normal tab), then refresh.`;
}

// The followed subreddits, A to Z, for the Reddit tab's menu. An empty list when
// Reddit can't be reached or isn't logged in; the feed itself reports why.
export async function fetchSubreddits({ hasHostAccess, log = console } = {}) {
  if (hasHostAccess && !(await hasHostAccess(SOURCES.reddit.origin))) return { subreddits: [] };
  try {
    return { subreddits: await fetchSubscribedSubreddits() };
  } catch (error) {
    log.warn(`[Royal feeds] subreddits: ${error?.constructor?.name ?? "Error"}: ${error?.message ?? error}`);
    return { subreddits: [] };
  }
}

export async function fetchFeed({ source, options } = {}, { hasHostAccess, log = console } = {}) {
  if (!Object.hasOwn(SOURCES, source)) throw new Error("Unknown feed source.");
  const spec = SOURCES[source];
  const chosen = validOptions(source, options);
  const started = Date.now();
  if (hasHostAccess && !(await hasHostAccess(spec.origin))) {
    log.warn(`[Royal feeds] ${source}: host access not granted for ${spec.origin}`);
    return { source, state: "noAccess", message: `Royal doesn't have access to ${new URL(spec.origin.replace("/*", "/")).host}. In the browser's extension Details, set Site access to allow it, then refresh.` };
  }
  try {
    const posts = (await spec.fetch(chosen)).map(normalizePost).filter(Boolean);
    log.info(`[Royal feeds] ${source}: ${posts.length} posts in ${Date.now() - started} ms`);
    return { source, state: "ok", posts };
  } catch (error) {
    log.warn(`[Royal feeds] ${source}: ${error?.constructor?.name ?? "Error"}: ${error?.message ?? error} (${Date.now() - started} ms)`);
    if (error instanceof NotLoggedInError) return { source, state: "notLoggedIn", login: spec.login, message: loginMessage(source, error) };
    if (error instanceof TypeError) {
      // Browser network failures, including redirects to hosts Royal can't access
      // (for example YouTube consent or Google sign-in pages).
      const hint = source === "youtube" ? " YouTube may have redirected to a sign-in or consent page. Open youtube.com in a normal tab, finish any prompt, then refresh." : " Check your connection and refresh.";
      return { source, state: "error", message: `Couldn't reach ${spec.name}.${hint}` };
    }
    if (source === "reddit" && /^Reddit blocked /.test(error?.message ?? "")) {
      return { source, state: "error", message: `Reddit's network security refused ${error.message.slice("Reddit blocked ".length)}. This is not a login prompt: Reddit blocks some networks and request types.` };
    }
    return { source, state: "error", message: `${spec.name}: ${error?.message ?? "fetch failed"}` };
  }
}
