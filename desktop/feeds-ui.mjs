// Feed list in the extension page. Each source is requested from the worker
// separately so one slow or logged-out site doesn't hold up the others.
const form = document.querySelector("#feed-options");
const refresh = document.querySelector("#refresh-feeds");

function age(created) {
  if (!created) return null;
  const minutes = Math.max(0, Math.round((Date.now() / 1000 - created) / 60));
  if (minutes < 60) return `${minutes}m`;
  if (minutes < 48 * 60) return `${Math.round(minutes / 60)}h`;
  return `${Math.round(minutes / 1440)}d`;
}

function link(href, text, className) {
  const a = document.createElement("a");
  a.href = href; a.textContent = text; a.target = "_blank"; a.rel = "noopener noreferrer";
  if (className) a.className = className;
  return a;
}

function renderPost(post) {
  const item = document.createElement("li");
  item.append(link(post.url, post.title, "title"));
  const meta = document.createElement("span");
  meta.className = "meta";
  const parts = [post.label, post.score != null && `${post.score} points`, post.published ?? age(post.created), post.nsfw && "NSFW"].filter(Boolean);
  meta.append(parts.join(" · "));
  if (post.comments != null && post.commentsUrl !== post.url) meta.append(" · ", link(post.commentsUrl, `${post.comments} comments`));
  item.append(meta);
  return item;
}

function render(section, result) {
  const status = section.querySelector(".feed-status");
  const list = section.querySelector("ol");
  status.classList.toggle("problem", result.state !== "ok");
  status.replaceChildren();
  if (result.state === "ok") {
    status.textContent = result.posts.length ? `${result.posts.length} posts` : "No posts.";
    list.replaceChildren(...result.posts.map(renderPost));
    return;
  }
  list.replaceChildren();
  status.append(result.message ?? "Feed failed.");
  if (result.state === "notLoggedIn" && result.login) status.append(" ", link(result.login, `Open ${new URL(result.login).host}`));
}

async function load(source, options) {
  const section = document.querySelector(`.feed[data-source="${source}"]`);
  section.querySelector(".feed-status").textContent = "Loading…";
  try {
    const result = await chrome.runtime.sendMessage({ action: "feed", source, options });
    render(section, result?.ok ? result : { state: "error", message: result?.message });
  } catch {
    render(section, { state: "error", message: "Could not reach the Royal extension worker. Reload this page and try again." });
  }
}

async function loadAll() {
  refresh.disabled = true;
  const values = new FormData(form);
  const reddit = values.get("reddit") === "top" ? { sort: "top", timeframe: "day" } : { sort: "best" };
  try {
    await Promise.all([
      load("reddit", reddit),
      load("hn", { list: "top" }),
      load("youtube", { feed: values.get("youtube") }),
    ]);
  } finally { refresh.disabled = false; }
}

form.addEventListener("submit", event => { event.preventDefault(); loadAll(); });
loadAll();
