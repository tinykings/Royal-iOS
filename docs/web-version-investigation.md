# Royal web version investigation

Investigated November 10, 2026. Scope: browse Royal's feeds on desktop and sync
Royal's saved items with iOS. A browser extension is acceptable to the owner.
This is a proposed design; authenticated browser fetching and cross-platform
sync have not been prototyped.

Implementation update: the selected first experiment is now an extension-only
CloudKit HTTP client, with a native private-record probe in Debug and
Release/TestFlight builds. See
[`desktop/README.md`](../desktop/README.md) for setup, acceptance checks, and the
Apple origin/callback requirements. A hosted web UI remains a fallback.

Result (2026-11-10): extension-only sign-in works with the
`chromiumapp.org` callback and an Any Domain web API token, and the private
probe record syncs both ways with a Production TestFlight build. No hosted
fallback is needed for authentication.
Feeds (2026-11-10, extension 0.2.0): the extension fetches Reddit, Hacker News
and YouTube with the shared `sources.js` from its service worker. In Chromium
156, worker and page fetches to host-permitted origins send all unpartitioned
cookies, even with third-party cookies blocked. Verified live with desktop
logins: Reddit Best/Top, HN, and YouTube Subscriptions/Home all load. See the
desktop README.
Only All's explicit-refresh snapshot, seen state, and saved items will sync;
individual source sections remain local. The probe does not connect real data yet.

## Recommendation

Build a responsive web app with a small browser extension for authenticated feed
requests. Start with a Chromium proof of concept, then confirm the owner's target
browser before investing in packaging or distribution. Use CloudKit private
records for shared saved items if the iCloud web sign-in proof of concept works.

Keep the SwiftUI app. Reuse `sources.js` and the normalized post format across
clients; implement the web presentation separately. A framework choice can wait
until the feed and sync proofs of concept succeed.

## What exists today

- `sources.js` fetches and normalizes Reddit, Hacker News, and YouTube posts.
  IDs already distinguish sources: Reddit `t3_…`, Hacker News `hn_…`, YouTube
  `yt_…`. The exported functions can be reused as JavaScript modules.
- `Royal/FeedSession.swift` replaces JavaScript `fetch` with a bridge to native
  `URLSession`, using cookies from the app's `WKWebView` login profile. An ordinary
  website has no equivalent access to another site's cookies or native networking.
- `Royal/SavedPosts.swift` stores complete post snapshots plus `savedAt` in
  `NSUbiquitousKeyValueStore`, mirrored locally. It chooses a whole saved list by
  modification time; simultaneous edits can overwrite each other. Lists above
  the app's approximately 1 MB threshold stay local.
- `Royal/FeedStore.swift` observes iCloud changes and implements save/unsave.
  Feed caches and read/seen state are local. There is one saved collection;
  there is no separate favorites collection or upstream Reddit-save integration.
- `docs/index.html` is the existing marketing site, not a web app.

Interpret “saved/fav” as Royal's existing saved collection for the first version.
Separate favorites, provider likes/saves, read-state sync, and shared feed ordering
would be additional product decisions.

## Feed access

### Extension transport

Use a hosted web UI with an extension bridge limited to the Royal origin. The
extension's service worker performs approved provider requests with the desktop
browser's session; it returns normalized posts rather than cookies or raw login
pages. Desktop and mobile provider logins remain separate.

Chrome documents cross-origin requests from extension contexts with host
permissions. Content scripts alone retain the page's cross-origin restrictions.
Its cookie documentation also describes settings-dependent behavior, so permission
to fetch does not prove Royal's authenticated endpoints will work. See
[cross-origin extension requests](https://developer.chrome.com/docs/extensions/develop/concepts/network-requests)
and [extension cookies](https://developer.chrome.com/docs/extensions/develop/concepts/storage-and-cookies).

Prefer sharing the module through an injectable transport: the default remains
standard `fetch`, iOS supplies its native bridge, and the extension supplies its
background transport. Keep existing Node mocks working. Bundle extension code
locally; do not depend on downloading executable provider code at runtime.

The bridge should expose bounded operations such as fetch Reddit Top, fetch
YouTube subscriptions, and fetch YouTube Home. Validate operation parameters,
sender/origin, response size, redirects, and provider hosts. Do not expose a
general URL proxy to pages or send provider credentials to sync storage.

### Provider feasibility

Hacker News already uses its public Firebase API and needs no account. Its current
adapter is the simplest initial live feed. Reference:
[official HN API](https://github.com/HackerNews/API).

Reddit's current adapter uses logged-in website JSON endpoints. The extension
could preserve that behavior, but it may still encounter network-security
blocking. Treat this as the first feed feasibility check. The supported API
alternative requires OAuth and Reddit access approval; installing an extension
does not establish that approval. References:
[Reddit developer access](https://support.reddithelp.com/hc/en-us/articles/14945211791892-Developer-Platform-Accessing-Reddit-Data)
and [Data API guidance](https://support.reddithelp.com/hc/en-us/articles/16160319875092-Reddit-Data-API-Wiki).

YouTube's current adapter parses subscription and Home page data. Try it through
the extension using a signed-in desktop session, including consent redirects and
expired login. This preserves the possibility of the existing Home feed but
retains its undocumented-format maintenance risk.

For an extension-free version, Google's API can list subscribed channels and
retrieve their uploads. That reconstructs a subscriptions feed and needs OAuth,
quota planning, and caching. It does not reproduce personalized Home: the API's
`home` activity parameter is deprecated. References:
[subscriptions](https://developers.google.com/youtube/data/reference/rest/v3/subscriptions/list),
[channel uploads](https://developers.google.com/youtube/data/guides/implementation/videos),
and [activities](https://developers.google.com/youtube/data/reference/rest/v3/activities/list).

A backend proxy alone cannot inherit a user's logged-in desktop session. A PWA
also retains normal browser origin and cookie restrictions. Neither removes the
need for an extension or a supported authentication/data integration.

## Shared saved items

### Preferred first experiment: CloudKit

Royal currently enables iCloud key-value storage, not a CloudKit database. These
are different services: CloudKit JS does not expose the current saved list.
Create a CloudKit container and schema, add native CloudKit support, and use its
private database from both clients. The web client needs iCloud authentication
and web-service configuration. Apple explicitly supports web access to the same
public/private CloudKit databases used by native apps. References:
[CloudKit JS](https://developer.apple.com/documentation/CloudKitJS?changes=latest_major)
and [enabling CloudKit](https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app).

This retains an Apple-based identity without adding a separate Royal account
service. Validate web authentication, allowed origins, account availability, and
native/web access to the same private record before committing to this choice.
Private records scope each user's saves; no public shared saves database is needed.

If iCloud web access proves unsuitable, use an authenticated sync API and database
instead. It would require stable user identity on both clients, ownership checks,
and account/deletion handling. Sign in with Apple by itself would not expose
existing iCloud storage. Keep the saved-item interface independent of the backend.

### Record and conflict design

Store one record per user and post, not one serialized array:

```text
postID        existing stable FeedPost.id; deterministic record key
post          versioned normalized snapshot
savedAt       explicit UTC timestamp; preserves saved-list ordering
isSaved       false retains an unsave tombstone
schemaVersion snapshot schema version
revision      storage-provided change tag/version
```

Keep local snapshots and a durable pending-operation queue on both clients
(IndexedDB on web). Apply saves locally immediately. Sync when connectivity
returns and when the app resumes; refresh while the web app is active. Do not
depend on reliable background execution or instantaneous delivery.

Use conditional writes with the server revision. Different post IDs merge
independently. For the same post, reject stale writes, fetch the current revision,
and reapply a pending local intention under a documented conflict rule. A practical
first rule is that the last successfully accepted intention wins; an offline edit
can therefore win when it reconnects. Coalesce pending operations per post and
make retries idempotent. Do not order competing devices by their wall clocks.
Retain tombstones until a deliberate cleanup/full-resync strategy exists so stale
clients cannot silently resurrect unsaved items.

Use an explicit wire date format. Existing Swift `JSONEncoder` uses its default
Date encoding for `savedAt`, whereas post publication times are Unix seconds;
copying numbers between the two would produce incorrect dates.

### Migration

On iOS, read the existing saved list through `SavedPostsStorage.load()`, preserve
its local backup, and import by stable ID without overwriting an existing remote
record or tombstone. Persist migration completion per account only after uploads
succeed; retries must be safe. Import the local copy too, including saves that
exceeded the current cloud size limit.

Once migrated, the new service becomes authoritative for saves. Avoid continuous
two-way mirroring with the old whole-list store: old app versions could otherwise
reintroduce removed items. Explain that older Royal builds stop participating in
new sync. Account changes must clear the prior account's visible data and keep
its pending operations isolated.

Stored provider snapshots also need provider-specific retention/deletion handling;
Reddit's linked API guidance requires removing deleted content. A saved bookmark
must not become an unconditional promise to retain a deleted post forever.

## Implementation sequence and acceptance checks

1. Prove extension access before building the full UI: followed subreddits,
   Reddit Best/Top, YouTube subscriptions/Home, pagination where applicable,
   logged-out states, cookie restrictions, and redirects. Confirm the target browser.
2. Prove a single private saved record can be written on iOS, read on web, unsaved
   on web, and observed on iOS using the same account.
3. Build the responsive feed UI with All, source tabs, Saved, source login status,
   sorting, refresh, and external links. Include IndexedDB caching and clearly
   distinguish unavailable authenticated feeds when the extension is missing.
4. Add durable save sync and migration. Verify independent concurrent saves,
   offline unsave/reconnect, repeated retries, same-post conflicts, account switch,
   interrupted migration, and saves above the old storage limit.
5. Add video embedding and browser packaging after core browsing/sync works.
   Read-state sync and a separate favorites flag can follow if desired.

No production app behavior changed during this investigation. No authenticated
extension requests, CloudKit configuration, builds, or sync experiments were run.
