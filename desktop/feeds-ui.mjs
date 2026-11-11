// Royal's tabs: All (a stored snapshot, replaced only by Refresh All), one tab per
// source (fetched on demand, never changing All), and Saved. The worker owns the
// stored state; this page only renders what it returns, laid out per Settings.
import { PREFERENCES_KEY, layoutFor, loadPreferences, normalizePreferences, opensComments, savePreferences } from "./preferences.mjs";

const send = request => chrome.runtime.sendMessage(request).catch(() => ({ ok: false, message: "Could not reach the Royal extension worker. Reload this page and try again." }));
let savedIDs = new Set();
let preferences = await loadPreferences(chrome.storage.local);

// Ages in the largest whole unit, like iOS PostRow: "now", "5m", "3h", "2d", "4w", "3mo", "1y".
const AGE_UNITS = [[31536000, "y"], [2592000, "mo"], [604800, "w"], [86400, "d"], [3600, "h"], [60, "m"]];
function age(seconds) {
  for (const [unit, suffix] of AGE_UNITS) if (seconds >= unit) return `${Math.floor(seconds / unit)}${suffix}`;
  return "now";
}
const since = epochSeconds => age(Math.max(0, Date.now() / 1000 - epochSeconds));
// YouTube's "3 hours ago" or "Streamed 2 hours ago", counted from publishedAt; other text ("Live") as is.
function published(post) {
  if (!post.published) return null;
  if (post.publishedAt == null) return post.published;
  return (/^(Streamed|Premiered) /.exec(post.published)?.[0] ?? "") + since(post.publishedAt);
}
const compact = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
const count = (value, noun) => `${compact.format(value)} ${noun}${value === 1 ? "" : "s"}`;
const when = ms => new Date(ms).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });

function link(href, label, className) {
  const a = document.createElement("a");
  a.href = href; a.target = "_blank"; a.rel = "noopener noreferrer";
  if (label) a.textContent = label;
  if (className) a.className = className;
  return a;
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function image(src, className) {
  const img = element("img", className);
  img.src = src; img.alt = ""; img.loading = "lazy"; img.decoding = "async"; img.referrerPolicy = "no-referrer";
  return img;
}

const SOURCE_NAMES = { reddit: "Reddit", hn: "Hacker News", youtube: "YouTube" };
const SOURCE_MARKS = { reddit: "r", hn: "Y", youtube: "" };

// hqdefault exists for every video; larger sizes can be missing.
const thumbnail = post => (post.videoId ? `https://i.ytimg.com/vi/${post.videoId}/hqdefault.jpg` : post.image);
// Taller images are letterboxed to a square so one image can't fill the screen.
const TALLEST_IMAGE_ASPECT = 1;

// --- Player: YouTube plays in a player docked above the tabs, like iOS. ---
const player = document.querySelector("#player");
// The player sticks just below the sticky header, so it needs the header's height.
const header = document.querySelector("header");
new ResizeObserver(() => {
  document.documentElement.style.setProperty("--header-height", `${header.offsetHeight}px`);
}).observe(header);
let playingID = null;
function markPlaying() {
  for (const item of document.querySelectorAll("li.post")) item.classList.toggle("playing", item.dataset.postId === playingID);
}
function play(post) {
  const wasPlaying = playingID != null;
  playingID = post.id;
  player.querySelector("iframe").src = `https://www.youtube.com/embed/${encodeURIComponent(post.videoId)}?autoplay=1&rel=0`;
  document.querySelector("#player-title").textContent = post.title;
  document.querySelector("#player-label").textContent = post.label;
  document.querySelector("#player-open").href = post.url;
  keepInPlace(post.id, () => {
    player.hidden = false;
    // Starting to play can switch every feed to rows (Settings › YouTube).
    if (!wasPlaying && preferences.listWhilePlaying) rerender();
  });
  markPlaying();
}
function closePlayer() {
  const id = playingID;
  playingID = null;
  keepInPlace(id, () => {
    player.hidden = true;
    if (preferences.listWhilePlaying) rerender();
  });
  player.querySelector("iframe").src = "about:blank";
  markPlaying();
}
// Re-laying out the feeds keeps the post that was clicked where it was on screen,
// below the docked player.
function keepInPlace(postID, change) {
  const visible = () => [...document.querySelectorAll(`li.post[data-post-id="${CSS.escape(postID ?? "")}"]`)].find(item => item.offsetParent);
  const before = visible()?.getBoundingClientRect().top;
  change();
  const after = visible();
  if (before == null || !after) return;
  const below = player.hidden ? 0 : player.getBoundingClientRect().bottom + 8;
  window.scrollBy(0, after.getBoundingClientRect().top - Math.max(before, below));
}
document.querySelector("#player-close").addEventListener("click", closePlayer);

// A plain click on a video plays it here; modified and middle clicks open YouTube as links do.
function playsHere(anchor, post) {
  if (!post.videoId || preferences.youtubePlayback !== "inApp") return;
  anchor.addEventListener("click", event => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    play(post);
  });
}

function media(post, layout, href) {
  const src = thumbnail(post);
  if (!src) return null;
  const anchor = link(href, null, layout === "card" ? "media" : "thumb");
  anchor.tabIndex = -1;
  anchor.setAttribute("aria-hidden", "true");
  if (layout === "card" && post.videoId) {
    anchor.style.setProperty("--aspect", "16 / 9");
    anchor.append(image(src));
  } else if (layout === "card") {
    // Sized from Reddit's reported shape, not the loaded image, so the card doesn't jump.
    anchor.style.setProperty("--aspect", String(Math.max(post.imageAspect ?? 4 / 3, TALLEST_IMAGE_ASPECT)));
    anchor.append(image(src, "backdrop"), image(src, "fit"));
  } else anchor.append(image(src));
  // A dead image leaves the post as text rather than an empty frame.
  anchor.querySelector("img:last-child").addEventListener("error", () => anchor.remove(), { once: true });
  playsHere(anchor, post);
  return anchor;
}

// Reddit and YouTube show as cards with a large image or as rows, per Settings;
// Hacker News, and Saved (which mixes every source), as rows with a small
// thumbnail. A click opens the link or the comments, per Settings, and the
// details link to the other. As on iOS.
const host = url => { try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return null; } };
// A filled heart, tinted by the button: dim until hovered or saved.
const HEART = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12 21s-7.5-4.6-9.6-9.3C.9 8.2 3 4.5 6.7 4.5c2.1 0 3.6 1.1 5.3 3 1.7-1.9 3.2-3 5.3-3 3.7 0 5.8 3.7 4.3 7.2C19.5 16.4 12 21 12 21z"/></svg>';

function renderPost(post, { showsSource = false, saved = false } = {}) {
  const layout = layoutFor(post, preferences, { saved, playing: playingID != null });
  const comments = opensComments(post, preferences);
  const href = comments ? post.commentsUrl : post.url;
  const item = element("li", `post ${layout}${post.videoId ? " video" : ""}`);
  item.dataset.postId = post.id;
  item.classList.toggle("playing", post.id === playingID);
  const body = element("div", "details");
  const title = link(href, post.title, "title");
  playsHere(title, post);
  body.append(title);

  const meta = element("span", "meta");
  if (showsSource) {
    const mark = element("span", `source-icon ${post.source}`, SOURCE_MARKS[post.source]);
    mark.title = SOURCE_NAMES[post.source];
    mark.setAttribute("aria-hidden", "true");
    meta.append(mark);
  }
  const text = element("span");
  const parts = [post.label || SOURCE_NAMES[post.source], post.score != null && count(post.score, "pt"),
    post.created != null ? since(post.created) : published(post), post.nsfw && "NSFW"].filter(Boolean);
  text.append(parts.join(" · "));
  const other = post.commentsUrl !== post.url;
  if (post.comments != null) {
    text.append(" · ");
    text.append(other && !comments ? link(post.commentsUrl, count(post.comments, "comment")) : count(post.comments, "comment"));
  }
  // Hacker News labels already name the link's site.
  if (other && comments) text.append(" · ", link(post.url, host(post.url) === post.label ? "link" : host(post.url) ?? "link"));
  meta.append(text);
  body.append(meta);

  const picture = media(post, layout, href);
  if (layout === "card") item.append(...[picture, body].filter(Boolean));
  else item.append(...[body, picture].filter(Boolean));

  const save = element("button", "save");
  save.innerHTML = HEART;
  const update = () => {
    const saved = savedIDs.has(post.id);
    save.setAttribute("aria-pressed", String(saved));
    save.title = saved ? "Unsave" : "Save";
    save.setAttribute("aria-label", saved ? `Unsave ${post.title}` : `Save ${post.title}`);
  };
  save.dataset.postId = post.id;
  save.update = update;
  save.addEventListener("click", async () => {
    save.disabled = true;
    const result = await send({ action: "setSaved", post, saved: !savedIDs.has(post.id) });
    save.disabled = false;
    if (result.ok) applyLibrary(result, { all: false });
  });
  update();
  item.append(save);
  return item;
}

function renderProblem(target, result) {
  target.append(result.message ?? "Feed failed.");
  if (result.state === "notLoggedIn" && result.login) target.append(" ", link(result.login, `Open ${new URL(result.login).host}`));
}

// --- All ---
const allStatus = document.querySelector("#all-status");
let shownAll = null, shownSaved = null;
// Earlier (seen) posts stay hidden until asked for, and hide again on Refresh All
// or Mark all read.
let showsEarlier = false;
const showEarlier = document.querySelector("#show-earlier");
function renderEarlierToggle() {
  const earlier = shownAll?.seen.length ?? 0;
  showEarlier.hidden = earlier === 0;
  showEarlier.setAttribute("aria-expanded", String(showsEarlier));
  showEarlier.textContent = showsEarlier ? "Hide earlier posts" : `Show ${earlier} earlier post${earlier === 1 ? "" : "s"}`;
  document.querySelector("#all-seen").hidden = !showsEarlier;
}
showEarlier.addEventListener("click", () => { showsEarlier = !showsEarlier; renderEarlierToggle(); });
function renderAll(all) {
  shownAll = all;
  const earlierTitle = document.querySelector("#all-earlier-title");
  document.querySelector("#all-new").replaceChildren(...all.new.map(post => renderPost(post, { showsSource: true })));
  document.querySelector("#all-seen").replaceChildren(...all.seen.map(post => renderPost(post, { showsSource: true })));
  earlierTitle.hidden = all.seen.length === 0;
  earlierTitle.textContent = all.previousRefresh ? `Earlier · shown before ${when(all.previousRefresh)}` : "Earlier";
  renderEarlierToggle();
  // New posts have to be marked read before All can refresh again.
  for (const button of document.querySelectorAll("#mark-read, #mark-read-bottom")) button.hidden = all.new.length === 0;
  document.querySelector("#refresh-all").hidden = all.new.length > 0;
  allStatus.textContent = all.refreshedAt
    ? `Refreshed ${when(all.refreshedAt)}: ${all.new.length} new, ${all.seen.length} earlier.`
    : "Not refreshed yet.";
  document.querySelector("#all-problems").replaceChildren(...Object.entries(all.errors ?? {}).map(([source, error]) => {
    const item = document.createElement("li");
    item.append(`${SOURCE_NAMES[source]}: `);
    renderProblem(item, error);
    item.append(" Showing its posts from the previous refresh, if any.");
    return item;
  }));
}

// --- Saved ---
function renderSaved(saved) {
  shownSaved = saved;
  document.querySelector("#saved-list").replaceChildren(...saved.map(post => renderPost(post, { showsSource: true, saved: true })));
  document.querySelector("#saved-status").textContent = saved.length ? `${saved.length} saved` : "Nothing saved yet. Use ♥ on any post.";
}

let isSignedIn = false;
let isSyncing = false;

function renderSync(sync, message, signedIn) {
  if (signedIn !== undefined) isSignedIn = signedIn;
  const signInNeeded = sync?.enabled && !isSignedIn;
  isSyncing = Boolean(sync?.enabled && isSignedIn);
  const account = document.querySelector("#account");
  account.textContent = isSignedIn ? "Sign out" : "Sign in with Apple";
  account.classList.toggle("secondary", isSignedIn);
  const status = document.querySelector("#sync-status");
  if (!sync?.enabled) {
    status.textContent = message ?? "Not signed in.";
    return;
  }
  const last = sync.lastSync ? `last synced ${when(sync.lastSync)}` : "not synced yet";
  const pending = sync.pending ? `, ${sync.pending} change${sync.pending === 1 ? "" : "s"} pending` : "";
  status.textContent = message ?? (signInNeeded ? `Sync is paused until you sign in again${pending}.` : `Signed in and syncing: ${last}${pending}.`);
}

function applyLibrary(result, { all = true } = {}) {
  renderSync(result.sync, result.syncMessage, result.signedIn);
  savedIDs = new Set(result.saved.map(post => post.id));
  if (all) renderAll(result.all);
  renderSaved(result.saved);
  for (const button of document.querySelectorAll("button.save")) button.update?.();
}

async function library(action) {
  const buttons = document.querySelectorAll("#tab-all .actions button");
  buttons.forEach(button => { button.disabled = true; });
  if (action === "refreshAll") allStatus.textContent = isSyncing ? "Syncing, then refreshing…" : "Refreshing…";
  const result = await send({ action });
  buttons.forEach(button => { button.disabled = false; });
  if (result.ok) applyLibrary(result);
  else allStatus.textContent = result.message ?? "Failed.";
}

document.querySelector("#refresh-all").addEventListener("click", () => { showsEarlier = false; library("refreshAll"); });
for (const button of document.querySelectorAll("#mark-read, #mark-read-bottom")) button.addEventListener("click", () => { showsEarlier = false; library("markAllRead"); });

// --- Source tabs: fetched on first open and on Refresh; never stored in All. ---
async function loadSource(panel) {
  const source = panel.dataset.source;
  const form = panel.querySelector("form");
  const status = panel.querySelector(".feed-status");
  const options = Object.fromEntries(new FormData(form));
  if (source === "reddit" && options.sort === "top") options.timeframe = "day";
  if (source === "reddit" && !options.subreddit) delete options.subreddit;
  status.textContent = "Loading…";
  status.classList.remove("problem");
  form.querySelector("button").disabled = true;
  const result = await send({ action: "feed", source, options });
  form.querySelector("button").disabled = false;
  panel.dataset.loaded = "true";
  const list = panel.querySelector("ol");
  if (result.ok && result.state === "ok") {
    status.textContent = result.posts.length ? `${result.posts.length} posts` : "No posts.";
    panel.posts = result.posts;
  } else {
    status.classList.add("problem");
    status.replaceChildren();
    renderProblem(status, result);
    panel.posts = [];
  }
  list.replaceChildren(...panel.posts.map(post => renderPost(post)));
}
for (const panel of document.querySelectorAll(".source-tab")) {
  const form = panel.querySelector("form");
  form.addEventListener("submit", event => { event.preventDefault(); loadSource(panel); });
  // Picking another list, feed, sort or subreddit loads it straight away.
  form.addEventListener("change", () => loadSource(panel));
}

// Reddit: everything followed, or one followed subreddit. A single subreddit only
// has Top (sources.js), so Best is unavailable while one is chosen, as on iOS.
const redditPanel = document.querySelector("#tab-reddit");
const redditForm = redditPanel.querySelector("form");
function updateRedditSort() {
  const one = Boolean(redditForm.elements.subreddit.value);
  if (one) redditForm.elements.sort.value = "top";
  redditForm.elements.sort.querySelector('option[value="best"]').disabled = one;
}
redditForm.elements.subreddit.addEventListener("change", updateRedditSort);
let subredditsLoaded = false;
async function loadSubreddits() {
  if (subredditsLoaded) return;
  subredditsLoaded = true;
  const result = await send({ action: "subreddits" });
  if (!result.ok || !result.subreddits?.length) { subredditsLoaded = false; return; }
  const select = redditForm.elements.subreddit;
  const chosen = select.value;
  const options = result.subreddits.map(name => Object.assign(element("option", null, `r/${name}`), { value: name }));
  select.replaceChildren(select.options[0], ...options);
  select.value = result.subreddits.includes(chosen) ? chosen : "";
  updateRedditSort();
}

// Lays out what's already shown again, after a Settings change or the player opening or closing.
function rerender() {
  if (shownAll) renderAll(shownAll);
  if (shownSaved) renderSaved(shownSaved);
  for (const panel of document.querySelectorAll(".source-tab")) {
    if (panel.posts) panel.querySelector("ol").replaceChildren(...panel.posts.map(post => renderPost(post)));
  }
}

// --- Settings: like iOS Settings, for this browser only. ---
const settingsForm = document.querySelector("#settings-form");
function showPreferences() {
  for (const field of settingsForm.elements) {
    if (!(field.name in preferences)) continue;
    if (field.type === "checkbox") field.checked = preferences[field.name];
    else field.value = preferences[field.name];
  }
  settingsForm.elements.listWhilePlaying.disabled = preferences.youtubePlayback !== "inApp";
}
function applyPreferences(next) {
  next = normalizePreferences(next);
  if (JSON.stringify(next) === JSON.stringify(preferences)) return;
  preferences = next;
  showPreferences();
  rerender();
}
settingsForm.addEventListener("submit", event => event.preventDefault());
settingsForm.addEventListener("change", () => {
  const next = Object.fromEntries([...settingsForm.elements].filter(field => field.name)
    .map(field => [field.name, field.type === "checkbox" ? field.checked : field.value]));
  applyPreferences(next);
  savePreferences(chrome.storage.local, preferences);
});
// Other Royal tabs in this browser follow along.
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes[PREFERENCES_KEY]) applyPreferences(changes[PREFERENCES_KEY].newValue);
});
showPreferences();

// --- Tabs ---
function show(tab) {
  for (const button of document.querySelectorAll("nav.tabs button")) button.setAttribute("aria-selected", String(button.dataset.tab === tab));
  for (const panel of document.querySelectorAll(".tab-panel")) panel.hidden = panel.id !== `tab-${tab}`;
  const panel = document.querySelector(`#tab-${tab}`);
  if (panel.classList.contains("source-tab") && !panel.dataset.loaded) loadSource(panel);
  if (tab === "reddit") loadSubreddits();
}
for (const button of document.querySelectorAll("nav.tabs button")) button.addEventListener("click", () => show(button.dataset.tab));

// --- Sync ---
async function syncAction(action) {
  const buttons = document.querySelectorAll("#account");
  buttons.forEach(button => { button.disabled = true; });
  document.querySelector("#sync-status").textContent = action === "signOut" ? "Signing out…" : action === "signIn" ? "Signing in…" : "Syncing…";
  const result = await send({ action });
  buttons.forEach(button => { button.disabled = false; });
  if (result.ok) applyLibrary(result);
  else document.querySelector("#sync-status").textContent = result.message ?? "Sync failed.";
  return result;
}
// Signing in turns sync on and syncs straight away; signing out turns it off.
document.querySelector("#account").addEventListener("click", () => syncAction(isSignedIn ? "signOut" : "signIn"));
// The worker syncs after local changes and tells open pages when it's done.
chrome.runtime.onMessage.addListener(message => {
  if (message?.event === "libraryChanged") send({ action: "library" }).then(result => { if (result.ok) applyLibrary(result); });
});

// Opening Royal shows the stored All snapshot; it refreshes only when asked,
// except the very first time, when there's nothing stored.
const initial = await send({ action: "library" });
if (initial.ok) {
  applyLibrary(initial);
  // Opening Royal checks for changes from other devices first (no request when
  // signed out).
  const current = initial.sync.enabled || initial.signedIn ? await syncAction("sync") : initial;
  if (current.ok && !current.all.refreshedAt) library("refreshAll");
} else allStatus.textContent = initial.message ?? "Failed to load.";
