// Serializes changes to the stored library so overlapping messages (or a worker
// restart mid-refresh) can't lose updates. Fetching happens outside the lock.
import { ALL_SOURCES, applyAllRefresh, emptyState, markAllRead, savedPosts, setSaved, splitByRefresh } from "./library.mjs";

export const LIBRARY_KEY = "royalLibrary";

export function createLibrary({ storage, fetchFeed, now = () => Date.now() }) {
  let queue = Promise.resolve();
  let refreshing = null;
  const load = async () => {
    const { [LIBRARY_KEY]: stored } = await storage.get(LIBRARY_KEY);
    return stored?.version === 1 ? stored : emptyState();
  };
  // Runs `change` on the latest stored state and saves what it returns.
  const update = change => {
    const run = queue.then(async () => {
      const state = await load();
      const next = change(state);
      if (next !== state) await storage.set({ [LIBRARY_KEY]: next });
      return next;
    });
    queue = run.catch(() => {});
    return run;
  };

  const view = state => {
    const split = splitByRefresh(state);
    return {
      all: {
        new: split.new, seen: split.seen, errors: state.all.errors,
        refreshedAt: state.all.refreshedAt, previousRefresh: state.all.previousRefresh,
        hasMarkedRead: state.hasMarkedRead,
      },
      saved: savedPosts(state),
    };
  };

  return {
    async view() { return view(await update(state => state)); },
    // Concurrent refresh requests share one fetch.
    refreshAll() {
      refreshing ??= (async () => {
        try {
          const results = Object.fromEntries(await Promise.all(ALL_SOURCES.map(async ({ source, options }) => [source, await fetchFeed({ source, options })])));
          return view(await update(state => applyAllRefresh(state, results, now())));
        } finally { refreshing = null; }
      })();
      return refreshing;
    },
    async markAllRead() { return view(await update(state => markAllRead(state, now()))); },
    async setSaved(post, saved) { return view(await update(state => setSaved(state, post, Boolean(saved), new Date(now())))); },
  };
}
