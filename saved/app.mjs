// Royal Saved's page: sign in with Apple, show the saved posts, play videos, unsave.
// Storage, sign-in and sync are in site.mjs; posts render as the extension's Saved tab.
import { createSite, describeCloudKitError, CloudKitError, takeCallback } from "./site.mjs";
import { normalizePreferences, opensComments, PREFERENCES_KEY } from "./shared/preferences.mjs";

const main = document.querySelector("main");
// Inside another site's frame, stay hidden, so nobody can trick clicks on Unsave
// or Sign out. (GitHub Pages can't send frame-ancestors.)
if (window.top !== window.self) throw new Error("Royal Saved won't run inside another page.");
main.hidden = false;

const $ = selector => document.querySelector(selector);
const notice = $("#notice");
function showNotice(text) { notice.textContent = text ?? ""; notice.hidden = !text; }

let site;
try {
  // Throws when the browser blocks site data for this page.
  localStorage.getItem(PREFERENCES_KEY);
  site = createSite({ storage: localStorage, pending: sessionStorage, locks: navigator.locks });
} catch {
  showNotice("Royal Saved needs this browser to allow site data (cookies and storage) for royal.tinyk.ing.");
  throw new Error("Storage unavailable.");
}

// --- Preferences: a few of the extension's Settings, for this browser only. ---
const readPreferences = () => { try { return normalizePreferences(JSON.parse(localStorage.getItem(PREFERENCES_KEY))); } catch { return normalizePreferences(null); } };
let preferences = readPreferences();
const settingsForm = $("#settings-form");
function showPreferences() {
  for (const field of settingsForm.elements) {
    if (!(field.name in preferences)) continue;
    if (field.type === "checkbox") field.checked = preferences[field.name];
    else field.value = preferences[field.name];
  }
}
settingsForm.addEventListener("submit", event => event.preventDefault());
settingsForm.addEventListener("change", () => {
  const changed = Object.fromEntries([...settingsForm.elements].filter(field => field.name)
    .map(field => [field.name, field.type === "checkbox" ? field.checked : field.value]));
  preferences = normalizePreferences({ ...preferences, ...changed });
  try { localStorage.setItem(PREFERENCES_KEY, JSON.stringify(preferences)); } catch {}
  render();
});
showPreferences();

// --- Formatting, as in the extension (iOS PostRow). ---
const AGE_UNITS = [[31536000, "y"], [2592000, "mo"], [604800, "w"], [86400, "d"], [3600, "h"], [60, "m"]];
function age(seconds) {
  for (const [unit, suffix] of AGE_UNITS) if (seconds >= unit) return `${Math.floor(seconds / unit)}${suffix}`;
  return "now";
}
const since = epochSeconds => age(Math.max(0, Date.now() / 1000 - epochSeconds));
function published(post) {
  if (!post.published) return null;
  if (post.publishedAt == null) return post.published;
  return (/^(Streamed|Premiered) /.exec(post.published)?.[0] ?? "") + since(post.publishedAt);
}
const compact = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
const count = (value, noun) => `${compact.format(value)} ${noun}${value === 1 ? "" : "s"}`;
const when = ms => new Date(ms).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
const host = url => { try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return null; } };

// Titles and labels come from Reddit and YouTube users, so everything is built as
// DOM nodes with textContent; nothing is ever parsed as HTML.
function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}
function link(href, label, className) {
  const a = element("a", className, label);
  a.href = href; a.target = "_blank"; a.rel = "noopener noreferrer";
  return a;
}
function image(src) {
  const img = element("img");
  img.src = src; img.alt = ""; img.loading = "lazy"; img.decoding = "async"; img.referrerPolicy = "no-referrer";
  return img;
}
function heart() {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(ns, "path");
  path.setAttribute("fill", "currentColor");
  path.setAttribute("d", "M12 21s-7.5-4.6-9.6-9.3C.9 8.2 3 4.5 6.7 4.5c2.1 0 3.6 1.1 5.3 3 1.7-1.9 3.2-3 5.3-3 3.7 0 5.8 3.7 4.3 7.2C19.5 16.4 12 21 12 21z");
  svg.append(path);
  return svg;
}

const SOURCE_NAMES = { reddit: "Reddit", hn: "Hacker News", youtube: "YouTube" };
const SOURCE_MARKS = { reddit: "r", hn: "Y", youtube: "" };
// YouTube thumbnails, sharpest first: 1280×720, then 640×480, then 480×360, which
// every video has. A size a video lacks comes back as a 404 or a 120×90 gray stand-in.
const YOUTUBE_SIZES = ["maxresdefault", "sddefault", "hqdefault"];
const thumbnails = post => (post.videoId
  ? YOUTUBE_SIZES.map(size => `https://i.ytimg.com/vi/${encodeURIComponent(post.videoId)}/${size}.jpg`)
  : post.image ? [post.image] : []);

// --- Player, docked under the header. ---
const player = $("#player");
const header = $("header");
new ResizeObserver(() => document.documentElement.style.setProperty("--header-height", `${header.offsetHeight}px`)).observe(header);
let playingID = null;
function play(post) {
  playingID = post.id;
  player.querySelector("iframe").src = `https://www.youtube.com/embed/${encodeURIComponent(post.videoId)}?autoplay=1&rel=0`;
  $("#player-title").textContent = post.title;
  $("#player-label").textContent = post.label;
  $("#player-open").href = post.url;
  player.hidden = false;
  render();
  window.scrollTo({ top: 0, behavior: "smooth" });
}
$("#player-close").addEventListener("click", () => {
  playingID = null;
  player.hidden = true;
  player.querySelector("iframe").src = "about:blank";
  render();
});
function playsHere(anchor, post) {
  if (!post.videoId || preferences.youtubePlayback !== "inApp") return;
  anchor.addEventListener("click", event => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    play(post);
  });
}

const revealedNSFW = new Set();
function blursNSFW(anchor, post) {
  if (!post.nsfw || !preferences.blurNSFW || revealedNSFW.has(post.id)) return;
  anchor.classList.add("nsfw");
  anchor.title = "Click to show";
  anchor.addEventListener("click", event => {
    if (!anchor.classList.contains("nsfw")) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    revealedNSFW.add(post.id);
    anchor.classList.remove("nsfw");
    anchor.removeAttribute("title");
  });
}

// Posts are cards with a large image above the text. While a video plays, they turn
// into rows with a small thumbnail, so more of the list fits beside the player.
function renderPost(post) {
  const comments = opensComments(post, preferences);
  const href = comments ? post.commentsUrl : post.url;
  const card = playingID === null;
  const item = element("li", `post ${card ? "card" : "row"}${post.videoId ? " video" : ""}`);
  item.dataset.postId = post.id;
  item.classList.toggle("playing", post.id === playingID);
  const body = element("div", "details");
  const title = link(href, post.title, "title");
  playsHere(title, post);
  body.append(title);

  const meta = element("span", "meta");
  const mark = element("span", `source-icon ${post.source}`, SOURCE_MARKS[post.source]);
  mark.title = SOURCE_NAMES[post.source];
  mark.setAttribute("aria-hidden", "true");
  meta.append(mark);
  const text = element("span");
  text.append([post.label || SOURCE_NAMES[post.source], post.score != null && count(post.score, "pt"),
    post.created != null ? since(post.created) : published(post), post.nsfw && "NSFW"].filter(Boolean).join(" · "));
  const other = post.commentsUrl !== post.url;
  if (post.comments != null) {
    text.append(" · ", other && !comments ? link(post.commentsUrl, count(post.comments, "comment")) : count(post.comments, "comment"));
  }
  if (other && comments) text.append(" · ", link(post.url, host(post.url) === post.label ? "link" : host(post.url) ?? "link"));
  meta.append(text);
  body.append(meta);
  item.append(body);

  const [src, ...fallbacks] = thumbnails(post);
  if (src) {
    const anchor = link(href, null, card ? "media" : "thumb");
    anchor.tabIndex = -1;
    anchor.setAttribute("aria-hidden", "true");
    const img = image(src);
    // A dead image (an old Reddit preview link, say) leaves the post as text.
    const next = () => {
      if (fallbacks.length) img.src = fallbacks.shift();
      else anchor.remove();
    };
    img.addEventListener("error", next);
    if (post.videoId) img.addEventListener("load", () => { if (img.naturalWidth <= 120) next(); });
    if (card && !post.videoId && post.imageAspect) {
      // Very tall or wide images are shown whole, on a blurred copy that fills the card.
      const aspect = Math.min(Math.max(post.imageAspect, 0.8), 2);
      anchor.style.setProperty("--aspect", String(aspect));
      if (Math.abs(aspect - post.imageAspect) > 0.01) {
        img.classList.add("fit");
        const backdrop = image(src);
        backdrop.classList.add("backdrop");
        anchor.append(backdrop);
      }
    } else if (card && post.videoId) anchor.style.setProperty("--aspect", "16 / 9");
    anchor.append(img);
    blursNSFW(anchor, post);
    playsHere(anchor, post);
    if (card) item.prepend(anchor);
    else item.append(anchor);
  }

  const save = element("button", "save");
  save.append(heart());
  save.setAttribute("aria-pressed", "true");
  save.title = "Unsave";
  save.setAttribute("aria-label", `Unsave ${post.title}`);
  save.addEventListener("click", () => unsave(post, save));
  item.append(save);
  return item;
}

// --- State and rendering ---
let current = null; // the last view from site.mjs
let lastMessage = null;

function render() {
  if (!current) return;
  const signedIn = current.signedIn;
  const synced = current.sync?.enabled;
  const account = $("#account");
  account.textContent = signedIn ? "Sign out" : synced ? "Sign in again" : "Sign in with Apple";
  account.classList.toggle("secondary", signedIn);
  $("#intro").hidden = Boolean(synced || signedIn);
  const saved = current.saved;
  $("#saved-list").replaceChildren(...saved.map(renderPost));
  $("#saved-status").textContent = !synced ? "" : saved.length ? `${saved.length} saved` : "Nothing saved yet. Save posts with ♥ in Royal on iPhone.";
  const status = $("#sync-status");
  if (!synced) status.textContent = "";
  else {
    const last = current.sync.lastSync ? `Last synced ${when(current.sync.lastSync)}` : "Not synced yet";
    const pending = current.sync.pending ? `, ${current.sync.pending} change${current.sync.pending === 1 ? "" : "s"} pending` : "";
    status.textContent = `${last}${pending}.`;
  }
  showNotice(lastMessage ?? (synced && !signedIn ? "Your iCloud sign-in expired. Sign in again to see new saves; changes made here stay pending until then." : null));
}

function apply(result, { message } = {}) {
  current = result;
  lastMessage = message !== undefined ? message : result.message ?? null;
  render();
}

let syncing = null, syncTimer, lastSyncAt = 0;
function syncNow() {
  clearTimeout(syncTimer);
  syncing ??= (async () => {
    try {
      const view = await site.view();
      if (!view.signedIn) { apply(view, { message: null }); return; }
      apply(await site.sync());
      lastSyncAt = Date.now();
    } finally { syncing = null; }
  })();
  return syncing;
}
function scheduleSync(delay = 1500) {
  clearTimeout(syncTimer);
  syncTimer = setTimeout(syncNow, delay);
}
site.onLocalChange = () => scheduleSync();

// Unsaving removes the post straight away, with Undo for a slip.
let undoPost = null;
async function unsave(post, button) {
  button.disabled = true;
  apply(await site.setSaved(post, false), { message: null });
  undoPost = post;
  $("#undo-text").textContent = `Unsaved “${post.title.length > 60 ? `${post.title.slice(0, 57)}…` : post.title}”.`;
  $("#undo").hidden = false;
}
$("#undo-button").addEventListener("click", async () => {
  if (!undoPost) return;
  const post = undoPost;
  undoPost = null;
  $("#undo").hidden = true;
  apply(await site.setSaved(post, true), { message: null });
});

$("#account").addEventListener("click", async event => {
  const button = event.currentTarget;
  button.disabled = true;
  try {
    if (current?.signedIn) {
      const pending = current.sync?.pending ?? 0;
      if (pending && !confirm(`${pending} change${pending === 1 ? " hasn't" : "s haven't"} synced to iCloud yet and will be lost. Sign out anyway?`)) return;
      undoPost = null;
      $("#undo").hidden = true;
      apply(await site.signOut(), { message: "Signed out. Your saved posts are still in iCloud." });
      return;
    }
    $("#sync-status").textContent = "Opening Apple sign-in…";
    location.assign(await site.beginSignIn());
  } catch (error) {
    showNotice(error instanceof CloudKitError ? describeCloudKitError(error)
      : /token/i.test(error?.message ?? "") ? "Royal Saved isn't set up yet: it needs its CloudKit web API token (site.mjs)."
        : "Couldn't start Apple sign-in. Check your connection and try again.");
  } finally { button.disabled = false; }
});

// Other Royal Saved tabs in this browser follow along.
addEventListener("storage", event => {
  if (event.key === PREFERENCES_KEY) { preferences = readPreferences(); showPreferences(); render(); return; }
  if (event.key === null || event.key.startsWith("royal")) site.view().then(view => apply(view, { message: lastMessage }));
});
// Check for new saves when the page comes back into view, and every two minutes
// while it's showing.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && Date.now() - lastSyncAt > 15000) syncNow();
});
setInterval(() => { if (document.visibilityState === "visible") syncNow(); }, 120000);

// Coming back from Apple's sign-in: take the token out of the address bar first.
const callback = takeCallback(location.href, { pending: sessionStorage });
if (callback) history.replaceState(null, "", callback.cleanURL);
apply(await site.view(), { message: null });
if (callback?.token) {
  $("#sync-status").textContent = "Signing in…";
  apply(await site.finishSignIn(callback.token));
  lastSyncAt = Date.now();
} else {
  await syncNow();
  if (callback?.refused) { lastMessage = "That sign-in didn't start on this page, so it was ignored. Sign in again."; render(); }
}
