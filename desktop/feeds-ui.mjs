// Royal's tabs: All (a stored snapshot, replaced only by Refresh All), one tab per
// source (fetched on demand, never changing All), and Saved. The worker owns the
// stored state; this page only renders what it returns.
const send = request => chrome.runtime.sendMessage(request).catch(() => ({ ok: false, message: "Could not reach the Royal extension worker. Reload this page and try again." }));
let savedIDs = new Set();

function age(created) {
  if (!created) return null;
  const minutes = Math.max(0, Math.round((Date.now() / 1000 - created) / 60));
  if (minutes < 60) return `${minutes}m`;
  if (minutes < 48 * 60) return `${Math.round(minutes / 60)}h`;
  return `${Math.round(minutes / 1440)}d`;
}
const when = ms => new Date(ms).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });

function link(href, label, className) {
  const a = document.createElement("a");
  a.href = href; a.textContent = label; a.target = "_blank"; a.rel = "noopener noreferrer";
  if (className) a.className = className;
  return a;
}

const SOURCE_NAMES = { reddit: "Reddit", hn: "Hacker News", youtube: "YouTube" };

function renderPost(post, showsSource) {
  const item = document.createElement("li");
  const body = document.createElement("div");
  body.append(link(post.url, post.title, "title"));
  const meta = document.createElement("span");
  meta.className = "meta";
  const label = showsSource && post.source !== "hn" ? `${SOURCE_NAMES[post.source]} · ${post.label}` : post.label;
  const parts = [label, post.score != null && `${post.score} points`, post.published ?? age(post.created), post.nsfw && "NSFW"].filter(Boolean);
  meta.append(parts.join(" · "));
  if (post.comments != null && post.commentsUrl !== post.url) meta.append(" · ", link(post.commentsUrl, `${post.comments} comments`));
  body.append(meta);
  const save = document.createElement("button");
  save.className = "save";
  const update = () => {
    const saved = savedIDs.has(post.id);
    save.setAttribute("aria-pressed", String(saved));
    save.textContent = saved ? "♥ Saved" : "♡ Save";
    save.title = saved ? "Unsave" : "Save";
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
  item.append(body, save);
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
  document.querySelector("#all-new").replaceChildren(...all.new.map(post => renderPost(post, true)));
  document.querySelector("#all-seen").replaceChildren(...all.seen.map(post => renderPost(post, true)));
  earlierTitle.hidden = all.seen.length === 0;
  earlierTitle.textContent = all.previousRefresh ? `Earlier — shown before ${when(all.previousRefresh)}` : "Earlier";
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
  document.querySelector("#saved-list").replaceChildren(...saved.map(post => renderPost(post, true)));
  document.querySelector("#saved-status").textContent = saved.length ? `${saved.length} saved` : "Nothing saved yet. Use ♡ Save on any post.";
}

function applyLibrary(result, { all = true } = {}) {
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
    list.replaceChildren(...result.posts.map(post => renderPost(post, false)));
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

// Opening Royal shows the stored All snapshot; it refreshes only when asked,
// except the very first time, when there's nothing stored.
const initial = await send({ action: "library" });
if (initial.ok) {
  applyLibrary(initial);
  if (!initial.all.refreshedAt) library("refreshAll");
} else allStatus.textContent = initial.message ?? "Failed to load.";
