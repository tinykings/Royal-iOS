// One sync pass for the active account library: pull zone changes, then push
// pending intentions with conditional writes, pulling again after conflicts.
// Callers must serialize this with every other CloudKit request (token rotation).
import { CloudKitError } from "./cloudkit.mjs";
import { accountLibraryKey } from "./store.mjs";
import { applyPushResults, applyRemoteChanges, pendingCount, planPush } from "./sync.mjs";

const PUSH_BATCH = 100;
const MAX_ROUNDS = 4;

export class SyncPausedError extends Error {}

export async function runSync({ api, library, now = () => Date.now() }) {
  const settings = await library.settings();
  if (!settings) throw new SyncPausedError("Sync is off.");
  if (settings.environment !== api.config.environment || settings.container !== api.config.container) {
    throw new SyncPausedError("The CloudKit configuration changed. Sign out and sign in again.");
  }
  const account = await api.currentUser();
  if (account !== settings.account) {
    throw new SyncPausedError("Signed in to a different Apple Account than the one syncing. Sign out and sign in again.");
  }
  const key = accountLibraryKey(settings);
  const setSync = change => library.apply(key, state => ({ ...state, sync: { ...state.sync, ...change(state.sync) } }));

  let state = await library.read(key);
  if (!state?.sync) throw new SyncPausedError("This account's library is missing. Sign out and sign in again.");
  if (!state.sync.zoneReady) {
    await api.ensureSyncZone();
    state = await setSync(() => ({ zoneReady: true }));
  }

  let pulled = 0, pushed = 0, failed = 0;
  for (let round = 0; round < MAX_ROUNDS; round++) {
    // Pull every page of changes since the stored token.
    for (let page = 0; page < 50; page++) {
      let changes;
      try { changes = await api.zoneChanges(state.sync.syncToken); }
      catch (error) {
        if (!(error instanceof CloudKitError)) throw error;
        if (error.code === "ZONE_NOT_FOUND") {
          // The zone was deleted (for example from iCloud settings). Start over,
          // keeping local pending intentions; every record is created anew.
          await api.ensureSyncZone();
          state = await setSync(() => ({ zoneReady: true, syncToken: null, tags: {} }));
          continue;
        }
        if (["CHANGE_TOKEN_EXPIRED", "BAD_REQUEST"].includes(error.code) && state.sync.syncToken) {
          state = await setSync(() => ({ syncToken: null }));
          continue;
        }
        throw error;
      }
      pulled += changes.records.length;
      state = await library.apply(key, current => {
        const next = applyRemoteChanges(current, changes.records);
        next.sync.syncToken = changes.syncToken;
        return next;
      });
      if (!changes.moreComing) break;
    }

    const plan = planPush(state);
    if (plan.length === 0) break;
    let retry = false;
    for (let start = 0; start < plan.length; start += PUSH_BATCH) {
      const batch = plan.slice(start, start + PUSH_BATCH);
      const results = await api.modifySyncRecords(batch.map(item => item.operation));
      state = await library.apply(key, current => {
        const outcome = applyPushResults(current, batch, results);
        retry ||= outcome.retry;
        failed += outcome.failed;
        return outcome.state;
      });
      pushed += results.filter(result => !result.serverErrorCode).length;
    }
    if (!retry) break;
  }
  state = await setSync(() => ({ lastSync: now() }));
  return { pulled, pushed, failed, pending: pendingCount(state) };
}
