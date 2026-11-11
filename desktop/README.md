# Royal desktop extension

An unpacked Chromium extension (Chrome, Edge) that opens Royal in a full tab:
All, Reddit, Hacker News, YouTube and Saved, fetched with the shared root
`sources.js` and the desktop browser's own Reddit and YouTube logins. Optional
iCloud sync shares saved posts and seen posts with Royal on iOS, and the All
feed too between browsers. There is no Royal server: feeds come straight from the
sites, and sync uses Apple's CloudKit HTTP API with the user's private database.

## Install

1. Open `chrome://extensions` or `edge://extensions` and turn on developer mode.
2. **Load unpacked** and pick this `desktop/` folder. Click Royal's toolbar
   button to open it.
3. In normal tabs of the same browser profile, log into reddit.com and
   youtube.com and finish any cookie/consent prompts.

After pulling changes, **Reload** Royal on the extensions page and reopen its tab.

## Sync with iOS

Always on in iOS; on the desktop, on while signed in. Everything is in one
custom private zone, `RoyalSync`;
the record format and conflict rules are in
[docs/sync-schema.md](../docs/sync-schema.md).

| | iOS | Desktop |
|---|---|---|
| Saved posts (`RoyalSavedPost`) | ✓ | ✓ |
| Seen posts (`RoyalSeen`) | ✓ | ✓ |
| All feed snapshot (`RoyalAllSnapshot`) | — | ✓ (between browsers) |

**Turning it on**

- iOS: nothing to do. Royal syncs with the Apple Account signed in to iCloud;
  **Settings › Sync** shows its state.
- Desktop: **iCloud Sync** tab → **Sign in with Apple** with the Apple Account on
  the iPhone. Being signed in is what turns sync on (since 0.6.2; there are no
  separate sync buttons), so expect "Synced. Received …, sent …" straight away.
  **Sign out** (the same button) turns it off.

There's nothing to configure: the container, web API token, and Production
environment are built into `cloudkit.mjs` (`ROYAL_CLOUDKIT`). The extension
always uses Production, as TestFlight and App Store builds do; Xcode Debug builds
of iOS use Development, so they don't sync with it. (Before 0.6.1 these were
entered by hand; 0.6.1 drops that setting, and the sign-in made with it unless
it matched.)

Both sides must use the same Apple Account. Signing in imports the browser's own
library without overwriting anything already synced, including unsaves
(tombstones). Each Apple Account has its own copy in the browser. Signing out
switches back to the browser's own library and keeps that account's copy, with
anything still pending, for its next sign-in; another account never sees it.
Someone signed in by 0.6.1 or earlier without sync on starts syncing the next
time Royal opens. Clearing the browser's extension data removes everything.

**When it syncs:** on sign-in, when the page opens, about 1.5 s after each
change, and just before **Refresh All**, so posts another device has shown are
already under Earlier. There's no background timer. A failed sync (offline,
sign-in expired) keeps changes pending, in the library's storage, so they survive
restarts; Refresh All still runs.

On iOS, sync runs when the app opens or returns to the foreground, after each
change, and during an All refresh (which waits up to 4 s for it). Until sync has
turned on for an account (no iCloud account, or iCloud not ready), iOS keeps saves
on the device and imports them when it does. If another Apple Account signs in to
iCloud, iOS switches to it, keeping the previous account's copy and pending changes
apart for its return. iOS no longer uses iCloud key-value storage: it reads the
old saved list there once, imports it, and never writes it.

**Sign-in:** the CloudKit web auth token is kept in `chrome.storage.local`
(trusted contexts only), so it survives browser restarts and extension updates.
**Sign out** removes it (do this on a shared computer). If Apple expires it,
that isn't a sign-out: sync pauses with changes pending, and the feed page shows
**Sign in to iCloud**.

Seen means *shown by All*, not read: a desktop refresh nobody looked at still
makes those posts not-new on the next iOS refresh.

## Apple setup (once, done)

Recorded for rebuilding the setup; all of this is in place for
`iCloud.com.tinykings.Royal`.

1. **Container.** `iCloud.com.tinykings.Royal` is registered for team
   `7F4K5N55BN` and associated with App ID `com.tinykings.Royal` with CloudKit
   (key-value storage stays on too). The app declares it in `Royal.entitlements`
   and as `RoyalCloudKitContainer` in `Info.plist`; `ROYAL_CLOUDKIT_ENVIRONMENT`
   is `Development` for Debug and `Production` for Release. Xcode Cloud's
   provisioning profile must include the container.
2. **Schema.** Production never creates record types itself. In CloudKit Console
   → **Development** → Schema → Record Types, create these, then **Deploy Schema
   Changes…** to Production:
   - `RoyalSavedPost`: `postID` String, `post` String, `savedAt` String,
     `isSaved` Int(64), `schemaVersion` Int(64)
   - `RoyalSeen`: `ids` String, `sources` String, `schemaVersion` Int(64)
   - `RoyalAllSnapshot`: `snapshot` String, `schemaVersion` Int(64)

   No indexes are needed. Royal creates the `RoyalSync` zone itself. (An older
   `RoyalSyncProbe` type from the sign-in test is unused and can stay.) A sync
   error naming a record type, or `BAD_REQUEST` on `records/modify`, means the
   schema isn't deployed.
3. **Callback.** The extension ID is fixed by the public `key` in
   `manifest.json`, so the callback is the same in every folder, profile and
   Chromium browser:
   `https://mddlclgijonpcbbehfggjpijpjlnakcp.chromiumapp.org/cloudkit` (also shown
   in the iCloud Sync tab). The private key is only for packing a `.crx` and isn't
   in the repository.
4. **Web API token.** In CloudKit Console, create a web API token for the
   container with that callback as its URL redirect and **Allowed Origins: Any
   Domain**. Console prefixes restricted domains with `https://`, so
   `chrome-extension://<id>` can never match (`AUTHENTICATION_FAILED`, HTTP 401).
   A web API token isn't a secret; private data still needs the user's Apple
   sign-in. The cost is that other sites could use it to show sign-in for this
   container. Untested hardening: rewrite the extension's `Origin` to its
   `chromiumapp.org` host and allow only that. The token is `ROYAL_CLOUDKIT.apiToken`
   in `cloudkit.mjs`; if it's regenerated, update it there and release a new
   version (existing sign-ins may need to sign in again).

## How it works

### Feeds

- `desktop/sources.js` is a **byte-for-byte copy** of the root `sources.js`,
  because an unpacked extension can only load files inside its own folder.
  `desktop/feeds.test.mjs` fails if they differ. After changing the root file, run
  `cp sources.js desktop/sources.js` and `node --test`. (A symlink breaks on
  Windows checkouts without symlink support.)
- The service worker runs the fetches (`feeds.mjs`) and returns only display
  fields (title, http(s) links, label, score, comments, age). The page
  (`feeds-ui.mjs`) sends one bounded message per source: `reddit` (`sort`
  best/top, `timeframe`), `hn` (`list` top/new), `youtube` (`feed`
  subscriptions/home). Anything else is refused; there is no URL proxy.
- Host permissions: `www.reddit.com`, `hacker-news.firebaseio.com`,
  `www.youtube.com`, `api.apple-cloudkit.com`; CSP `connect-src` lists the same.
  There's no `cookies` permission: cookies come from the browser's normal jar
  because `sources.js` uses `credentials: "include"`.
- Per source: a list, **Log into <site> in this browser** (`NotLoggedInError`),
  **no access** (site access withheld, checked with `chrome.permissions.contains`),
  or an error. A redirect to an unpermitted host (such as `consent.youtube.com`)
  fails as `TypeError: Failed to fetch` and is reported as a possible sign-in or
  consent page; the host list deliberately doesn't include Google's.
- Why the worker: in Chromium 156, worker and page fetches to host-permitted
  origins both send every unpartitioned cookie (`SameSite` Strict/Lax/None,
  `HttpOnly`), even with third-party cookies blocked; only `Partitioned` (CHIPS)
  cookies aren't sent. Running in the worker keeps provider responses and
  CloudKit tokens out of the page. Verified live with desktop logins on
  2026-11-10 (Reddit Best/Top, HN, YouTube Subscriptions/Home).

### All, seen, and saved

A port of `Royal/FeedStore.swift` (`library.mjs`, `store.mjs`):

- **All** is a stored snapshot of Reddit Top today, Hacker News Top (30, iOS's
  first page) and YouTube Subscriptions, alternated per source with repeated
  links kept once. It changes only on **Refresh All** (and the first time, when
  nothing is stored). Source tabs never change it. A source that fails keeps its
  previous posts and says why.
- **New vs. earlier** follows `splitByRefresh`: posts not shown by an earlier
  refresh are new; YouTube's are those above the newest seen video, or published
  after the previous refresh when none was seen; a source new to All isn't marked
  new. **Mark all read** moves everything to Earlier. Seen ids are capped at 3000.
- **Saved**: ♡ on any post. One entry per post id with a sanitized snapshot, ISO
  8601 `savedAt`, and `isSaved`; unsaving keeps a tombstone. Newest first.
- Stored in `chrome.storage.local` (`royalLibrary`, trusted contexts only);
  updates are serialized, so a save during a refresh is kept.

### Sync

`sync.mjs` and `sync-runner.mjs` pull zone changes (`records/changes` with a sync
token), then push pending intentions with conditional `records/modify` writes
(`update` with the last change tag, or `create`). On `CONFLICT`/`EXISTS` they pull
and reapply: a saved post's last intention wins, seen is unioned, a pending All
refresh replaces the snapshot and a pending Mark all read is reapplied on top. A
deleted zone is recreated and pending intentions pushed again. Service-worker
console lines starting with `[Royal sync]` hold counts and CloudKit error codes
only, never tokens.

### Page and video

`feeds-ui.mjs` and `style.css` follow iOS `PostRow` and the site's palette in
light and dark mode: cards for Reddit and YouTube, 96×54 rows for Hacker News and
Saved. A plain click on a YouTube post plays it in a player docked above the
tabs; ⌘/Ctrl/middle click opens YouTube. The embed won't play without a referrer
(error 153) and extension pages send none, so one session `declarativeNetRequest`
rule sets `Referer: https://tinykings.github.io/` (as iOS does) on
`www.youtube.com/embed/` sub-frames this extension's page loads
(`declarativeNetRequestWithHostAccess`, no install warning).

### Security

No content scripts, external messaging, remote code, or `cookies` permission.
CloudKit operations are limited to the caller identity and the `RoyalSync` zone
of the private database. Only Royal's own page can message the worker. User
tokens never reach the page or the console; the worker serializes CloudKit
requests and adopts rotated tokens. **Sign out** clears Royal's credentials, not
the browser's Apple login.

## Troubleshooting

**Apple login completes, then "Apple sign-in didn't come back".** Apple
redirected to a different callback. Set the token's redirect URL to exactly the
callback in setup step 3. The worker console logs which extension ID Apple's
login link names (`[Royal sign-in]`).

**`NETWORK_ERROR` before an Apple window opens.** Click **Check connection** in
the iCloud Sync tab. It uses an intentionally invalid token, so HTTP 401
(`AUTHENTICATION_FAILED`) means CloudKit is reachable; it doesn't touch your real
token or session.

- Host access missing: allow Royal access to `api.apple-cloudkit.com` in the
  extension's Details.
- Reachable but sign-in fails: check in CloudKit Console that Royal's web API
  token still exists, for Production, with Any Domain origins and the callback.
- No HTTP response: open Royal's **service worker** inspector from the extensions
  page, retry, and note the browser error (`net::ERR_…`, a CSP violation). Request
  URLs contain tokens, so share only the error code or status, never full URLs or
  a HAR.

**A feed fails.** Send the `[Royal feeds]` console lines (source, error class,
message, timing; no cookies) and the HTTP status of the failing request. Don't
export a HAR or copy request headers: they contain session cookies.

## Still to do

- **Live edge cases with iOS:** seen sync from iOS, concurrent saves on both
  sides, offline unsave then reconnect, same-post conflict, Apple Account switch,
  an interrupted first import, and the one-time import of a large key-value list.
  Unit tests cover these against `fake-cloudkit.mjs` (test-only, not loaded by
  the extension).
- **All snapshot on iOS:** leaning against. Seen sync already keeps posts one
  device showed from coming back as New on the other. Adopting it would make
  iOS's All a stored snapshot, and iOS would have to split it with the
  snapshot's own `previouslySeen`/`previousRefresh` rather than its merged seen
  ids, or everything the desktop just showed would land under Earlier unread.
- **Retention** of saved snapshots of content deleted upstream (Reddit's terms).
- **Dropping the key-value entitlement** on iOS once every device has run the
  one-time import.
- **Extension UI:** Settings-like choices (card/list, open link vs. comments),
  NSFW handling for saved posts, and checking the design with real feeds.
- **Distribution:** it's loaded unpacked; the Chrome Web Store would need a
  packed build and a privacy policy.

## Local checks

Run `node --test` at the repository root. It also checks that
`desktop/sources.js` matches the root `sources.js` and that `fetch` is called as
a plain function (Chromium rejects it as a method with "Illegal invocation").
Tests mock CloudKit; they can't establish Apple login, provisioning, or record
access.

References: [CloudKit web services](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html),
[record writes](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ModifyRecords.html),
[users/caller](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/FetchCurrentUserIdentity.html),
[Chrome identity](https://developer.chrome.com/docs/extensions/reference/api/identity),
[iCloud configuration](https://developer.apple.com/documentation/xcode/configuring-icloud-services/),
[schema deployment](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema).
