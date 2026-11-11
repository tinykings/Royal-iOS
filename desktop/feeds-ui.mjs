// Royal's tabs: All (a stored snapshot, replaced only by Refresh All), one tab per
// source (fetched on demand, never changing All), and Saved. The worker owns the
// stored state; this page only renders what it returns.
const send = request => chrome.runtime.sendMessage(request).catch(() => ({ ok: false, message: "Could not reach the Royal extension worker. Reload this page and try again." }));
let savedIDs = new Set();

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
let playingID = null;
function markPlaying() {
  for (const item of document.querySelectorAll("li.post")) item.classList.toggle("playing", item.dataset.postId === playingID);
}
function play(post) {
  playingID = post.id;
  player.querySelector("iframe").src = `https://www.youtube.com/embed/${encodeURIComponent(post.videoId)}?autoplay=1&rel=0`;
  document.querySelector("#player-title").textContent = post.title;
  document.querySelector("#player-label").textContent = post.label;
  document.querySelector("#player-open").href = post.url;
  player.hidden = false;
  markPlaying();
}
function closePlayer() {
  playingID = null;
  player.hidden = true;
  player.querySelector("iframe").src = "about:blank";
  markPlaying();
}
document.querySelector("#player-close").addEventListener("click", closePlayer);

// A plain click on a video plays it here; modified and middle clicks open YouTube as links do.
function playsHere(anchor, post) {
  if (!post.videoId) return;
  anchor.addEventListener("click", event => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    play(post);
  });
}

function media(post, layout) {
  const src = thumbnail(post);
  if (!src) return null;
  const anchor = link(post.url, null, layout === "card" ? "media" : "thumb");
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

// Reddit and YouTube show as cards with a large image; Hacker News, and Saved
// (which mixes every source), as rows with a small thumbnail. As on iOS.
function renderPost(post, { showsSource = false, layout } = {}) {
  layout ??= post.source === "hn" ? "row" : "card";
  const item = element("li", `post ${layout}${post.videoId ? " video" : ""}`);
  item.dataset.postId = post.id;
  item.classList.toggle("playing", post.id === playingID);
  const body = element("div", "details");
  const title = link(post.url, post.title, "title");
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
  if (post.comments != null) {
    text.append(" · ");
    text.append(post.commentsUrl !== post.url ? link(post.commentsUrl, count(post.comments, "comment")) : count(post.comments, "comment"));
  }
  meta.append(text);
  body.append(meta);

  const picture = media(post, layout);
  if (layout === "card") item.append(...[picture, body].filter(Boolean));
  else item.append(...[body, picture].filter(Boolean));

  const save = element("button", "save");
  const update = () => {
    const saved = savedIDs.has(post.id);
    save.setAttribute("aria-pressed", String(saved));
    save.textContent = saved ? "♥" : "♡";
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
function renderAll(all) {
  const earlierTitle = document.querySelector("#all-earlier-title");
  document.querySelector("#all-new").replaceChildren(...all.new.map(post => renderPost(post, { showsSource: true })));
  document.querySelector("#all-seen").replaceChildren(...all.seen.map(post => renderPost(post, { showsSource: true })));
  earlierTitle.hidden = all.seen.length === 0;
  earlierTitle.textContent = all.previousRefresh ? `Earlier · shown before ${when(all.previousRefresh)}` : "Earlier";
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
  document.querySelector("#saved-list").replaceChildren(...saved.map(post => renderPost(post, { showsSource: true, layout: "row" })));
  document.querySelector("#saved-status").textContent = saved.length ? `${saved.length} saved` : "Nothing saved yet. Use ♡ on any post.";
}

function renderSync(sync, message, signInNeeded = false) {
  const note = document.querySelector("#sync-note");
  document.querySelector("#sync-sign-in").hidden = !(sync?.enabled && signInNeeded);
  const status = document.querySelector("#sync-status");
  if (!sync?.enabled) {
    note.textContent = "Stored in this browser only.";
    status.textContent = message ?? "Sync is off.";
    return;
  }
  const last = sync.lastSync ? `last synced ${when(sync.lastSync)}` : "not synced yet";
  const pending = sync.pending ? `, ${sync.pending} change${sync.pending === 1 ? "" : "s"} pending` : "";
  note.textContent = signInNeeded
    ? `iCloud sync is paused until you sign in again${pending}.`
    : `Synced through iCloud (${sync.environment}): ${last}${pending}.`;
  status.textContent = message ?? `Sync is on (${sync.environment}): ${last}${pending}.`;
}

function applyLibrary(result, { all = true } = {}) {
  renderSync(result.sync, result.syncMessage, result.signInNeeded);
  savedIDs = new Set(result.saved.map(post => post.id));
  if (all) renderAll(result.all);
  renderSaved(result.saved);
  for (const button of document.querySelectorAll("button.save")) button.update?.();
}

async function library(action) {
  const buttons = document.querySelectorAll("#tab-all .actions button");
  buttons.forEach(button => { button.disabled = true; });
  if (action === "refreshAll") allStatus.textContent = "Refreshing…";
  const result = await send({ action });
  buttons.forEach(button => { button.disabled = false; });
  if (result.ok) applyLibrary(result);
  else allStatus.textContent = result.message ?? "Failed.";
}

document.querySelector("#refresh-all").addEventListener("click", () => library("refreshAll"));
document.querySelector("#mark-read").addEventListener("click", () => library("markAllRead"));

// --- Source tabs: fetched on first open and on Refresh; never stored in All. ---
async function loadSource(panel) {
  const source = panel.dataset.source;
  const form = panel.querySelector("form");
  const status = panel.querySelector(".feed-status");
  const options = Object.fromEntries(new FormData(form));
  if (source === "reddit" && options.sort === "top") options.timeframe = "day";
  status.textContent = "Loading…";
  status.classList.remove("problem");
  form.querySelector("button").disabled = true;
  const result = await send({ action: "feed", source, options });
  form.querySelector("button").disabled = false;
  panel.dataset.loaded = "true";
  const list = panel.querySelector("ol");
  if (result.ok && result.state === "ok") {
    status.textContent = result.posts.length ? `${result.posts.length} posts` : "No posts.";
    list.replaceChildren(...result.posts.map(post => renderPost(post)));
  } else {
    status.classList.add("problem");
    status.replaceChildren();
    renderProblem(status, result);
    list.replaceChildren();
  }
}
for (const panel of document.querySelectorAll(".source-tab")) {
  panel.querySelector("form").addEventListener("submit", event => { event.preventDefault(); loadSource(panel); });
}

// --- Tabs ---
function show(tab) {
  for (const button of document.querySelectorAll("nav.tabs button")) button.setAttribute("aria-selected", String(button.dataset.tab === tab));
  for (const panel of document.querySelectorAll(".tab-panel")) panel.hidden = panel.id !== `tab-${tab}`;
  const panel = document.querySelector(`#tab-${tab}`);
  if (panel.classList.contains("source-tab") && !panel.dataset.loaded) loadSource(panel);
}
for (const button of document.querySelectorAll("nav.tabs button")) button.addEventListener("click", () => show(button.dataset.tab));

// --- Sync ---
async function syncAction(action) {
  const buttons = document.querySelectorAll("#sync-title ~ .actions button");
  buttons.forEach(button => { button.disabled = true; });
  document.querySelector("#sync-status").textContent = "Syncing…";
  const result = await send({ action });
  buttons.forEach(button => { button.disabled = false; });
  if (result.ok) applyLibrary(result);
  else document.querySelector("#sync-status").textContent = result.message ?? "Sync failed.";
  return result;
}
// Signing in from the feed page, when sync paused for it, then syncing straight away.
document.querySelector("#sync-sign-in").addEventListener("click", async event => {
  event.target.disabled = true;
  const signedIn = await send({ action: "signIn" });
  event.target.disabled = false;
  if (signedIn.ok) syncAction("sync");
  else document.querySelector("#sync-note").textContent = signedIn.message ?? "Sign-in failed.";
});
document.querySelector("#sync-enable").addEventListener("click", () => syncAction("enableSync"));
document.querySelector("#sync-now").addEventListener("click", () => syncAction("sync"));
document.querySelector("#sync-disable").addEventListener("click", () => syncAction("disableSync"));
// The worker syncs after local changes and tells open pages when it's done.
chrome.runtime.onMessage.addListener(message => {
  if (message?.event === "libraryChanged") send({ action: "library" }).then(result => { if (result.ok) applyLibrary(result); });
});

// Opening Royal shows the stored All snapshot; it refreshes only when asked,
// except the very first time, when there's nothing stored.
const initial = await send({ action: "library" });
if (initial.ok) {
  applyLibrary(initial);
  // Opening Royal checks for changes from other devices first.
  const current = initial.sync.enabled ? await syncAction("sync") : initial;
  if (current.ok && !current.all.refreshedAt) library("refreshAll");
} else allStatus.textContent = initial.message ?? "Failed to load.";
