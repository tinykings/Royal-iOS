// CloudKit sync of the saved posts: wire format, merging remote changes, and
// planning conditional writes. Pure functions over the library state; the caller
// supplies CloudKit requests. The wire format is documented in
// docs/sync-schema.md; iOS implements the same. Royal Saved only reads and writes
// RoyalSavedPost records; iOS's RoyalSeen record is left alone.
//
// Local intentions are kept as dirty marks in state.sync.dirty, stored with the
// library, so they survive offline periods and page reloads and coalesce per
// item. Each mark records the state.sync.rev when it was made; a push clears it
// only if nothing changed the item again meanwhile.
//
// Conflict rules:
// - One record per post. The last accepted intention wins; a pending local
//   save/unsave is reapplied over a newer remote revision.
// - Unsaves are tombstones (isSaved 0), never deletions.
// - Imports (turning sync on with local data) never overwrite an existing remote
//   record or tombstone.
import { normalizePost } from "./library.mjs";

export const SCHEMA_VERSION = 1;
export const SAVED_RECORD_TYPE = "RoyalSavedPost";
const PREFIX = "saved.";
export const savedRecordName = postID => `${PREFIX}${postID}`;

export function emptySync() {
  return { rev: 0, syncToken: null, zoneReady: false, tags: {}, dirty: { saved: {} }, lastSync: null };
}

// --- Marking local intentions -------------------------------------------------

function bump(state) {
  const rev = state.sync.rev + 1;
  return { rev, sync: { ...state.sync, rev, dirty: { ...state.sync.dirty, saved: { ...state.sync.dirty.saved } } } };
}

// Marks a saved post's change (`change` is { saved: postID }) for the next push.
export function markDirty(state, change) {
  if (!state.sync) return state;
  const { rev, sync } = bump(state);
  if (change.saved) sync.dirty.saved[change.saved] = { rev, mode: "set" };
  return { ...state, sync };
}

// Turning sync on for an account: everything local is offered as an import.
export function startSync(localState) {
  const state = { ...structuredClone(localState), sync: emptySync() };
  const rev = 1;
  state.sync.rev = rev;
  for (const postID of Object.keys(state.saved)) state.sync.dirty.saved[postID] = { rev, mode: "import" };
  return state;
}

export function pendingCount(state) {
  const dirty = state.sync?.dirty;
  if (!dirty) return 0;
  return Object.keys(dirty.saved).length;
}

// --- Wire format ----------------------------------------------------------------

const str = value => ({ value, type: "STRING" });
const int = value => ({ value, type: "INT64" });
const ISO_DATE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;

function recordFor(state, recordName) {
  const postID = recordName.slice(PREFIX.length);
  const entry = state.saved[postID];
  return { recordType: SAVED_RECORD_TYPE, fields: {
    postID: str(postID), post: str(JSON.stringify(entry.post)), savedAt: str(entry.savedAt),
    isSaved: int(entry.isSaved ? 1 : 0), schemaVersion: int(SCHEMA_VERSION),
  } };
}

const field = (record, name) => record.fields?.[name]?.value;
const parse = value => { try { return JSON.parse(value); } catch { return undefined; } };

// Decodes a remote saved-post record; null when it's not one Royal Saved understands
// (including a newer schemaVersion, which is left untouched rather than misread).
export function decodeRecord(record) {
  if (!record || typeof record.recordName !== "string" || record.deleted) return null;
  if (!(field(record, "schemaVersion") <= SCHEMA_VERSION)) return null;
  if (record.recordType !== SAVED_RECORD_TYPE || !record.recordName.startsWith(PREFIX)) return null;
  const postID = field(record, "postID");
  const post = normalizePost(parse(field(record, "post")));
  const savedAt = field(record, "savedAt");
  if (record.recordName !== savedRecordName(postID) || !post || post.id !== postID || !ISO_DATE.test(savedAt ?? "")) return null;
  return { postID, entry: { post, savedAt: new Date(savedAt).toISOString(), isSaved: field(record, "isSaved") === 1 } };
}

// --- Applying remote changes ------------------------------------------------------

// Applies one page of records/changes. Records other than saved posts are skipped.
// Posts with pending local intentions keep the local value (and take the remote
// change tag, so the push can succeed).
export function applyRemoteChanges(state, records) {
  const next = structuredClone(state);
  const { sync } = next;
  for (const record of records) {
    const name = record?.recordName;
    if (typeof name !== "string" || !name.startsWith(PREFIX)) continue;
    const postID = name.slice(PREFIX.length);
    if (record.deleted) {
      // Royal never deletes; another client did. Forget the revision, and drop a
      // clean local copy.
      delete sync.tags[name];
      if (!sync.dirty.saved[postID]) delete next.saved[postID];
      continue;
    }
    const decoded = decodeRecord(record);
    if (typeof record.recordChangeTag === "string") sync.tags[name] = record.recordChangeTag;
    if (!decoded) continue;
    const pending = sync.dirty.saved[decoded.postID];
    if (pending?.mode === "import") delete sync.dirty.saved[decoded.postID];
    if (!pending || pending.mode === "import") next.saved[decoded.postID] = decoded.entry;
  }
  return next;
}

// --- Pushing ----------------------------------------------------------------------

// The conditional writes for every pending intention: update when the record's
// revision is known, otherwise create (which fails with EXISTS if another client
// created it first).
export function planPush(state) {
  const { dirty, tags } = state.sync;
  const items = Object.entries(dirty.saved).filter(([postID]) => state.saved[postID])
    .map(([postID, mark]) => ({ name: savedRecordName(postID), mark, postID }));
  return items.map(({ name, mark, postID }) => ({
    postID, rev: mark.rev,
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
    const { postID } = item;
    const mark = () => sync.dirty.saved[postID];
    const clear = () => { delete sync.dirty.saved[postID]; };
    if (!result.serverErrorCode && result.recordName === name && typeof result.recordChangeTag === "string") {
      sync.tags[name] = result.recordChangeTag;
      // Changed again while this push was in flight: keep it pending.
      if (mark()?.rev === item.rev) clear();
    } else if (["CONFLICT", "EXISTS"].includes(result.serverErrorCode)) {
      // Another client wrote first. An import yields to it; anything else is
      // reapplied once the next pull brings the newer revision.
      if (mark()?.mode === "import") clear();
      retry = true;
    } else failed++;
  });
  return { state: next, retry, failed };
}
