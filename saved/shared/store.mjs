// Stored library state. Each Apple Account that syncs gets its own library key, so
// switching accounts never shows (or pushes) another account's data or pending
// changes; without sync, the local library is used. All updates are serialized,
// so overlapping changes and a sync in flight can't lose one another.
import { emptyState, savedPosts, setSaved } from "./library.mjs";
import { markDirty, pendingCount } from "./sync.mjs";

export const LIBRARY_KEY = "royalLibrary";
export const SYNC_SETTINGS_KEY = "royalSyncSettings";
export const accountLibraryKey = ({ environment, container, account }) => `${LIBRARY_KEY}:${environment}:${container}:${account}`;

export function createLibrary({ storage, now = () => Date.now(), onChange = () => {} }) {
  let queue = Promise.resolve();

  const serialized = task => {
    const run = queue.then(task);
    queue = run.catch(() => {});
    return run;
  };
  const settings = async () => (await storage.get(SYNC_SETTINGS_KEY))[SYNC_SETTINGS_KEY] ?? null;
  const activeKey = async () => { const sync = await settings(); return sync ? accountLibraryKey(sync) : LIBRARY_KEY; };
  const load = async key => {
    const { [key]: stored } = await storage.get(key);
    return stored?.version === 1 ? stored : null;
  };
  // Runs `change` on the latest stored state at `key` (the active library when
  // omitted) and saves what it returns.
  const update = (change, key) => serialized(async () => {
    const target = key ?? await activeKey();
    const state = await load(target) ?? emptyState();
    const next = change(state);
    if (next !== state) await storage.set({ [target]: next });
    return next;
  });
  // A user change: also marked for sync when the active library syncs.
  const userChange = async (change, mark) => {
    let changed = false;
    const next = await update(state => {
      const after = change(state);
      if (after === state) return state;
      changed = true;
      return markDirty(after, mark);
    });
    if (changed && next.sync) onChange();
    return next;
  };

  const view = (state, syncSettings) => ({
    saved: savedPosts(state),
    sync: syncSettings && state.sync
      ? { enabled: true, environment: syncSettings.environment, pending: pendingCount(state), lastSync: state.sync.lastSync }
      : { enabled: false },
  });
  const currentView = async () => {
    const syncSettings = await settings();
    return view(await update(state => state), syncSettings);
  };

  return {
    settings,
    view: currentView,
    async setSaved(post, saved) {
      const postID = post?.id;
      await userChange(state => setSaved(state, post, Boolean(saved), new Date(now())), { saved: postID });
      return currentView();
    },

    // For the sync runner: read or update one library by key, serialized with
    // user changes.
    read: key => serialized(() => load(key)),
    apply: (key, change) => update(change, key),
    // Switches the active library. `initial` creates the account library if it
    // doesn't exist yet, from the local library.
    async useSync(syncSettings, initial) {
      await serialized(async () => {
        if (syncSettings) {
          const key = accountLibraryKey(syncSettings);
          if (!(await load(key))) await storage.set({ [key]: initial(await load(LIBRARY_KEY) ?? emptyState()) });
          await storage.set({ [SYNC_SETTINGS_KEY]: syncSettings });
        } else await storage.remove(SYNC_SETTINGS_KEY);
      });
      return currentView();
    },
  };
}
