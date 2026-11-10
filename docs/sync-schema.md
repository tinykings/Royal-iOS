# Royal CloudKit sync schema (v1, draft)

Status: implemented by the desktop extension (`desktop/sync.mjs`) and tested
against a fake CloudKit and between two desktop clients. **Not implemented on iOS
yet**. The desktop syncs in either environment; for Production the record types
below must be created in Development and deployed (Production never creates
them). iOS must read and write exactly this format before relying on it.

Console field types: every field is String except `isSaved` and
`schemaVersion`, which are Int(64). No indexes are required.

## Zone

Private database, custom zone **`RoyalSync`** (not the default zone), so clients
can fetch incremental changes with a sync token (`records/changes` on the web,
`CKFetchRecordZoneChangesOperation` / `CKSyncEngine` on iOS). Clients create the
zone if it's missing. If the zone disappears (the user deleted iCloud data), a
client recreates it and pushes its pending intentions again.

All string fields are UTF-8 JSON or text. Times are explicit:
`savedAt` is an ISO 8601 UTC string with milliseconds (`2026-11-10T22:04:05.123Z`);
times inside JSON are Unix epoch **milliseconds** (`refreshedAt`,
`previousRefresh`); post `created` / `publishedAt` stay Unix **seconds** as
`sources.js` produces them. Do not copy Swift `JSONEncoder`'s default `Date`
encoding into these fields.

Every record has `schemaVersion` (INT64, currently `1`). A client ignores records
with a higher version rather than misreading or overwriting them.

## Records

### `RoyalSavedPost`: one per post

| | |
|---|---|
| recordName | `saved.<postID>`, e.g. `saved.t3_abc123`, `saved.hn_42`, `saved.yt_dQw4w9WgXcQ` |
| `postID` | STRING, the `FeedPost.id` |
| `post` | STRING, JSON of the normalized post (`sources.js` / `FeedPost` keys) |
| `savedAt` | STRING, ISO 8601 UTC, time of the last save **or** unsave |
| `isSaved` | INT64, `1` saved, `0` unsaved (tombstone) |
| `schemaVersion` | INT64 |

Unsaving writes `isSaved = 0`; records are never deleted, so a stale client can't
resurrect them. Saved lists show `isSaved = 1` newest `savedAt` first.

### `RoyalSeen`: single record `seen`

| | |
|---|---|
| `ids` | STRING, JSON array of post ids All has shown, oldest first, at most 3000 |
| `sources` | STRING, JSON array of sources that have had posts in All (`reddit`, `hn`, `youtube`) |
| `schemaVersion` | INT64 |

A grow-only set. Merge = union: remote order first, then local ids it lacks, then
keep the newest 3000. Matches iOS `allFeedSeenIDs` / `allFeedSources`.

### `RoyalAllSnapshot`: single record `all`

| | |
|---|---|
| `snapshot` | STRING, JSON object below |
| `schemaVersion` | INT64 |

```json
{
  "lists": { "reddit": [FeedPost], "hn": [FeedPost], "youtube": [FeedPost] },
  "refreshedAt": 1762812245123,
  "previousRefresh": 1762790000000,
  "previouslySeen": ["t3_…", "hn_…"],
  "previousSources": ["reddit", "hn"],
  "hasMarkedRead": true
}
```

`lists` are the per-source lists of the last explicit All refresh (Reddit Top
today, HN Top, YouTube Subscriptions), before interleaving; each client
interleaves them (iOS `FeedStore.posts(_:)`) and splits new from earlier
(`splitByRefresh`) itself. Per-device fetch errors are not synced. Only an
explicit All refresh or Mark all read changes this record; single-source tabs never do.

## Writing and conflicts

- Writes are conditional: `update` with the last known `recordChangeTag`, or
  `create` when none is known (fails with `EXISTS` if another client created it).
  Never `forceUpdate` / `.allKeys` overwrite.
- Pending local intentions are durable and coalesced per record. On `CONFLICT` /
  `EXISTS`, fetch changes, then reapply:
  - Saved post: the pending save/unsave is written again over the newer revision
    (the last accepted intention wins; offline edits can win when they reconnect).
  - Seen: union, then write.
  - All: a pending refresh replaces the remote snapshot; a pending Mark all read
    is reapplied on top of the newest remote snapshot instead.
- Turning sync on with existing local data is an **import**: it creates records
  only where none exist and never overwrites a remote record or tombstone. (On
  iOS this is the migration from `NSUbiquitousKeyValueStore` saved posts, including
  any kept only locally above the old size limit.)
- Order competing devices by accepted writes, not by their clocks.

## Accounts

Data is per Apple Account (`userRecordName`) and per container/environment.
Changing account must hide the previous account's data and keep its pending
intentions apart, never pushing them to the new account.

## Not decided yet

- Retention and deletion of saved snapshots for content removed upstream (Reddit's
  API terms require removing deleted content).
- Whether iOS's YouTube "videos above the newest seen" rule stays per device or
  uses the synced snapshot's YouTube list (desktop uses the snapshot).
- When to retire the `NSUbiquitousKeyValueStore` saved list on iOS.
