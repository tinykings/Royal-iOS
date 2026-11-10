// CloudKit sync of the desktop library: wire format, merging remote changes,
// and planning conditional writes. Pure functions over the library state; the
// worker supplies CloudKit requests. The wire format is documented in
// docs/sync-schema.md; iOS must implement the same.
//
// Local intentions are kept as dirty marks in state.sync.dirty, stored with the
// library, so they survive offline periods and worker restarts and coalesce per
// item. Each mark records the state.sync.rev when it was made; a push clears it
// only if nothing changed the item again meanwhile.
//
// Conflict rules:
// - Saved posts: one record per post. The last accepted intention wins; a
//   pending local save/unsave is reapplied over a newer remote revision.
//   Unsaves are tombstones (isSaved 0), never deletions.
// - Seen: a grow-only set of ids, merged by union (capped at SEEN_LIMIT).
// - All snapshot: an explicit refresh replaces it (last accepted wins). A pending
//   Mark all read is reapplied on top of the newest remote snapshot instead.
// - Imports (turning sync on with local data) never overwrite an existing remote
//   record or tombstone.
import { markAllRead, normalizePost, SEEN_LIMIT } from "./library.mjs";

export const SCHEMA_VERSION = 1;
export const RECORD_TYPES = { saved: "RoyalSavedPost", seen: "RoyalSeen", all: "RoyalAllSnapshot" };
export const SEEN_RECORD = "seen";
export const ALL_RECORD = "all";
export const savedRecordName = postID => `saved.${postID}`;

export function emptySync() {
  return { rev: 0, syncToken: null, zoneReady: false, tags: {}, dirty: { saved: {}, seen: null, all: null }, lastSync: null };
}

// --- Marking local intentions -------------------------------------------------

function bump(state) {
  const rev = state.sync.rev + 1;
  return { rev, sync: { ...state.sync, rev, dirty: { ...state.sync.dirty, saved: { ...state.sync.dirty.saved } } } };
}

// What a library change means for sync. `change` is one of:
// { saved: postID } | { refresh: true } | { markRead: true }
export function markDirty(state, change) {
  if (!state.sync) return state;
  const { rev, sync } = bump(state);
  if (change.saved) sync.dirty.saved[change.saved] = { rev, mode: "set" };
  if (change.refresh || change.markRead) {
    sync.dirty.seen = { rev };
    const intent = change.refresh ? "replace" : sync.dirty.all?.intent === "replace" ? "replace" : "markRead";
    sync.dirty.all = { rev, intent };
  }
  return { ...state, sync };
}

// Turning sync on for an account: everything local is offered as an import.
export function startSync(localState) {
  const state = { ...structuredClone(localState), sync: emptySync() };
  const rev = 1;
  state.sync.rev = rev;
  for (const postID of Object.keys(state.saved)) state.sync.dirty.saved[postID] = { rev, mode: "import" };
  if (state.seen.length) state.sync.dirty.seen = { rev };
  if (state.all.refreshedAt) state.sync.dirty.all = { rev, intent: "import" };
  return state;
}

export function pendingCount(state) {
  const dirty = state.sync?.dirty;
  if (!dirty) return 0;
  return Object.keys(dirty.saved).length + (dirty.seen ? 1 : 0) + (dirty.all ? 1 : 0);
}

// --- Wire format ----------------------------------------------------------------

const str = value => ({ value, type: "STRING" });
const int = value => ({ value, type: "INT64" });
const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;

function snapshotJSON(state) {
  const { lists, refreshedAt, previousRefresh, previouslySeen, previousSources } = state.all;
  return JSON.stringify({ lists, refreshedAt, previousRefresh, previouslySeen, previousSources, hasMarkedRead: state.hasMarkedRead });
}

function recordFor(state, recordName) {
  if (recordName === SEEN_RECORD) {
    return { recordType: RECORD_TYPES.seen, fields: { ids: str(JSON.stringify(state.seen)), sources: str(JSON.stringify(state.sources)), schemaVersion: int(SCHEMA_VERSION) } };
  }
  if (recordName === ALL_RECORD) {
    return { recordType: RECORD_TYPES.all, fields: { snapshot: str(snapshotJSON(state)), schemaVersion: int(SCHEMA_VERSION) } };
  }
  const postID = recordName.slice("saved.".length);
  const entry = state.saved[postID];
  return { recordType: RECORD_TYPES.saved, fields: {
    postID: str(postID), post: str(JSON.stringify(entry.post)), savedAt: str(entry.savedAt),
    isSaved: int(entry.isSaved ? 1 : 0), schemaVersion: int(SCHEMA_VERSION),
  } };
}

const field = (record, name) => record.fields?.[name]?.value;
const parse = value => { try { return JSON.parse(value); } catch { return undefined; } };
const stringArray = (value, limit) => Array.isArray(value) && value.length <= limit && value.every(item => typeof item === "string") ? value : null;

// Decodes a remote record; null when it's not one Royal understands (including a
// newer schemaVersion, which is left untouched rather than misread).
export function decodeRecord(record) {
  if (!record || typeof record.recordName !== "string" || record.deleted) return null;
  if (!(field(record, "schemaVersion") <= SCHEMA_VERSION)) return null;
  if (record.recordType === RECORD_TYPES.saved && record.recordName.startsWith("saved.")) {
    const postID = field(record, "postID");
    const post = normalizePost(parse(field(record, "post")));
    const savedAt = field(record, "savedAt");
    if (record.recordName !== savedRecordName(postID) || !post || post.id !== postID || !ISO_DATE.test(savedAt ?? "")) return null;
    return { kind: "saved", postID, entry: { post, savedAt: new Date(savedAt).toISOString(), isSaved: field(record, "isSaved") === 1 } };
  }
  if (record.recordType === RECORD_TYPES.seen && record.recordName === SEEN_RECORD) {
    const ids = stringArray(parse(field(record, "ids")), SEEN_LIMIT * 2);
    const sources = stringArray(parse(field(record, "sources")), 10);
    return ids && sources ? { kind: "seen", ids, sources } : null;
  }
  if (record.recordType === RECORD_TYPES.all && record.recordName === ALL_RECORD) {
    const snapshot = parse(field(record, "snapshot"));
    if (!snapshot || typeof snapshot !== "object") return null;
    const lists = {};
    for (const source of ["reddit", "hn", "youtube"]) {
      if (!Array.isArray(snapshot.lists?.[source])) return null;
      lists[source] = snapshot.lists[source].map(normalizePost).filter(Boolean);
    }
    const time = value => (value === null || Number.isFinite(value) ? value : undefined);
    const all = {
      lists, errors: {}, refreshedAt: time(snapshot.refreshedAt), previousRefresh: time(snapshot.previousRefresh),
      previouslySeen: stringArray(snapshot.previouslySeen, SEEN_LIMIT * 2), previousSources: stringArray(snapshot.previousSources, 10),
    };
    if (Object.values(all).includes(undefined) || !all.previouslySeen || !all.previousSources) return null;
    return { kind: "all", all, hasMarkedRead: Boolean(snapshot.hasMarkedRead) };
  }
  return null;
}

// Union, remote order first, local additions after, newest kept under the cap.
export function mergeSeen(remote, local) {
  const set = new Set(remote);
  return [...remote, ...local.filter(id => !set.has(id))].slice(-SEEN_LIMIT);
}

// --- Applying remote changes ------------------------------------------------------

// Applies one page of records/changes. Records with pending local intentions keep
// the local value (and take the remote change tag, so the push can succeed).
export function applyRemoteChanges(state, records) {
  const next = structuredClone(state);
  const { sync } = next;
  for (const record of records) {
    if (typeof record?.recordName !== "string") continue;
    const name = record.recordName;
    if (record.deleted) {
      // Royal never deletes; another client did. Forget the revision, and drop a
      // clean local copy of a saved post.
      delete sync.tags[name];
      if (name.startsWith("saved.") && !sync.dirty.saved[name.slice(6)]) delete next.saved[name.slice(6)];
      continue;
    }
    const decoded = decodeRecord(record);
    if (typeof record.recordChangeTag === "string") sync.tags[name] = record.recordChangeTag;
    if (!decoded) continue;
    if (decoded.kind === "saved") {
      const pending = sync.dirty.saved[decoded.postID];
      if (pending?.mode === "import") delete sync.dirty.saved[decoded.postID];
      if (!pending || pending.mode === "import") next.saved[decoded.postID] = decoded.entry;
    } else if (decoded.kind === "seen") {
      next.seen = mergeSeen(decoded.ids, next.seen);
      next.sources = [...new Set([...decoded.sources, ...next.sources])].filter(source => ["reddit", "hn", "youtube"].includes(source));
      // Local ids the remote lacks still need pushing.
      const remoteIDs = new Set(decoded.ids);
      if (!sync.dirty.seen && next.seen.some(id => !remoteIDs.has(id))) sync.dirty.seen = { rev: sync.rev };
    } else if (decoded.kind === "all") {
      const pending = sync.dirty.all;
      if (pending?.intent === "replace") continue;
      next.all = decoded.all;
      next.hasMarkedRead = decoded.hasMarkedRead;
      if (pending?.intent === "import") sync.dirty.all = null;
      if (pending?.intent === "markRead") {
        const marked = markAllRead(next);
        next.all = marked.all; next.seen = marked.seen; next.hasMarkedRead = true;
      }
    }
  }
  return next;
}

// --- Pushing ----------------------------------------------------------------------

// The conditional writes for every pending intention: update when the record's
// revision is known, otherwise create (which fails with EXISTS if another client
// created it first).
export function planPush(state) {
  const { dirty, tags } = state.sync;
  const items = [
    ...Object.entries(dirty.saved).filter(([postID]) => state.saved[postID]).map(([postID, mark]) => ({ name: savedRecordName(postID), mark, key: ["saved", postID] })),
    ...(dirty.seen ? [{ name: SEEN_RECORD, mark: dirty.seen, key: ["seen"] }] : []),
    ...(dirty.all ? [{ name: ALL_RECORD, mark: dirty.all, key: ["all"] }] : []),
  ];
  return items.map(({ name, mark, key }) => ({
    key, rev: mark.rev,
    operation: {
      operationType: tags[name] ? "update" : "create",
      record: { recordName: name, ...recordFor(state, name), ...(tags[name] ? { recordChangeTag: tags[name] } : {}) },
    },
  }));
}

// Applies the results of a push. Returns { state, retry, failed }: retry is true
// when a conflict means remote changes must be pulled before trying again;
// failed counts items that were refused for another reason and stay pending.
export function applyPushResults(state, plan, results) {
  const next = structuredClone(state);
  const { sync } = next;
  let retry = false, failed = 0;
  plan.forEach((item, i) => {
    const result = results[i] ?? {};
    const name = item.operation.record.recordName;
    const [kind, postID] = item.key;
    const mark = () => (kind === "saved" ? sync.dirty.saved[postID] : sync.dirty[kind]);
    const clear = () => { if (kind === "saved") delete sync.dirty.saved[postID]; else sync.dirty[kind] = null; };
    if (!result.serverErrorCode && result.recordName === name && typeof result.recordChangeTag === "string") {
      sync.tags[name] = result.recordChangeTag;
      // Changed again while this push was in flight: keep it pending.
      if (mark()?.rev === item.rev) clear();
    } else if (["CONFLICT", "EXISTS"].includes(result.serverErrorCode)) {
      // Another client wrote first. An import yields to it; anything else is
      // reapplied once the next pull brings the newer revision.
      if (mark()?.mode === "import" || mark()?.intent === "import") clear();
      retry = true;
    } else failed++;
  });
  return { state: next, retry, failed };
}
