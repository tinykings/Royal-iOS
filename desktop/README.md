# Royal desktop extension (experiment)

This unpacked Chromium extension opens a full tab with two experiments:

1. **Feeds** (version 0.4.0): All, Reddit, Hacker News, YouTube and Saved tabs,
   fetched with the shared root `sources.js` and the desktop browser's own
   Reddit/YouTube logins. See [Feeds](#feeds) and [All, seen, and saved](#all-seen-and-saved).
   Optional CloudKit sync of All, seen and saved, desktop-to-desktop for now:
   see [Sync experiment](#sync-experiment).
2. **CloudKit sign-in and private-record probe** (below). It uses Apple's HTTP
   endpoints directly; it does not load a remote JavaScript SDK or require a
   hosted website.

**Status:** verified live on 2026-11-10 in the Production environment. Apple
sign-in completed inside the extension (no hosted page), and the private probe
record synced both ways between the extension and a TestFlight iOS build. This
needs a web API token whose Allowed Origins is Any Domain (see setup step 6).
It does not migrate saves or sync timeline/seen/saved data. Existing iOS storage remains authoritative and unchanged.

## Feeds

### How it works

- `desktop/sources.js` is a **byte-for-byte copy** of the root `sources.js`,
  because an unpacked extension can only load files inside its own folder. It is
  not a fork: `desktop/feeds.test.mjs` fails if the two differ. After changing
  the root file, run `cp sources.js desktop/sources.js` and `node --test`. (A
  symlink loads in Chrome on Linux, but git checkouts on Windows without
  symlink support turn it into a text file, so the copy is safer.)
- The service worker runs the fetches (`feeds.mjs`) and returns only display
  fields for each post (title, http(s) links, label, score, comments, age). The
  page (`feeds-ui.mjs`) sends one bounded message per source: `reddit`
  (`sort` best/top, `timeframe`), `hn` (`list` top/new), `youtube` (`feed`
  subscriptions/home). Any other source or option is refused; there is no URL
  proxy. Feed requests bypass the CloudKit queue, so they don't block the probe.
- Host permissions: `www.reddit.com`, `hacker-news.firebaseio.com`,
  `www.youtube.com`, plus the separate `api.apple-cloudkit.com` entry for
  CloudKit. CSP `connect-src` lists the same four hosts. There is still no
  `cookies` permission: cookies come from the browser's normal cookie jar
  because `sources.js` uses `credentials: "include"`.
- States per source: a list, **Log into <site> in this browser** (from
  `NotLoggedInError`, with a link to the site), **no access** (host permission
  withheld via Site access), or an error message.

### Page design and video (0.5.0)

`feeds-ui.mjs` and `style.css` follow iOS `PostRow` and the site's palette, in
light and dark mode:

- **Cards** for Reddit and YouTube: a large image above the title. Reddit images
  keep their reported shape (`imageAspect`), capped at square, on a blurred copy
  of themselves; YouTube uses `hqdefault` cropped to 16:9 with a play badge.
  **Rows** with a 96×54 thumbnail for Hacker News and Saved. Source marks,
  compact points/comments, iOS-style ages, and a heart in the corner (shown on
  hover until saved). All's new/earlier divider is a gold rule.
- **Video**: a plain click on a YouTube post plays it in a player docked above
  the tabs (the playing post is outlined); ⌘/Ctrl/middle click opens YouTube.
  The embed refuses to play without a referrer and extension pages send none, so
  the worker adds one session `declarativeNetRequest` rule setting `Referer:
  https://tinykings.github.io/` (as iOS does) on `www.youtube.com/embed/`
  sub-frames whose initiator is this extension only. Permission:
  `declarativeNetRequestWithHostAccess` (no install warning; uses the existing
  YouTube host access).
- Verified 2026-11-11 in Chromium 157 headless with the unpacked extension: the
  embed autoplays (video advancing, no `.ytp-error`); with the rule removed it
  stays at 0:00. Layout checked with mock posts in light and dark. Not yet
  checked with real logged-in feeds.

### All, seen, and saved

Added in 0.3.0 (`library.mjs`, `store.mjs`); a port of `Royal/FeedStore.swift`:

- **All** is a stored snapshot of Reddit Top today, Hacker News Top, and YouTube
  Subscriptions (iOS `FeedKey.combined`), alternated per source with repeated
  links kept once. It changes only on **Refresh All** (and automatically the
  first time, when nothing is stored). Opening Royal or using the source tabs
  never changes it. A source that fails keeps its posts from the previous refresh
  and shows why above the list.
- **New vs. earlier** follows `splitByRefresh`: posts not shown by an earlier
  refresh are new; YouTube's are those above the newest already-seen video, or
  published after the previous refresh when none was seen; a source new to All
  isn't marked new. **Mark all read** moves everything to Earlier. Seen ids are
  capped at 3000, like iOS. Unlike iOS, Earlier is always shown below New.
- **Saved**: ♡ Save on any post, in any tab. One entry per post id with a
  sanitized post snapshot, an ISO 8601 `savedAt`, and `isSaved`; unsaving keeps a
  tombstone, as the sync design requires. Newest first.
- The worker stores all of this in `chrome.storage.local` (key `royalLibrary`,
  trusted contexts only) and serializes updates, so a save during a refresh is
  kept. Source tabs are fetched on first open and on their Refresh button, and are
  not stored.
- Verified in Chrome for Testing 156 with the fake hosts: first-open refresh,
  save from All → Saved, source tabs leaving All unchanged, mark all read, a
  refresh afterwards, state surviving a browser restart, and unsave from Saved.

### Sync experiment

Added in 0.4.0 (`sync.mjs`, `sync-runner.mjs`); the wire format and conflict
rules are in [docs/sync-schema.md](../docs/sync-schema.md). iOS syncs saved posts
and seen (Settings › Web Sync Experiment › Sync with Desktop); the All snapshot
still syncs between desktop browsers only.

- Opt-in, in **iCloud probe → 4. Sync All, seen, and saved**, in whichever
  environment step 1 selects (Production or Development). It reads and writes
  only its own zone. iOS reads and writes its `RoyalSavedPost` and `RoyalSeen`
  records once Sync with Desktop is on there; with it off, iOS keeps saved posts in iCloud
  key-value storage only. While it's on, iOS mirrors the synced list into
  key-value storage, and imports saves it finds there that the zone has no record of. Production
  rejects record types that haven't been deployed, so set up the schema first
  (live test step 1).
- Records live in a custom private zone `RoyalSync`: one `RoyalSavedPost` per
  post (unsaves are tombstones), one `RoyalSeen` (union-merged), and one
  `RoyalAllSnapshot`. Writes are conditional on the change tag; conflicts pull
  and reapply the pending intention.
- Pending changes are stored with the library, so they survive being offline and
  browser restarts, and are sent on the next sync. Royal syncs when the page opens,
  about 1.5 s after each change, on **Sync now**, and (since 0.5.2) just before
  **Refresh All**, so posts another device has shown since the page opened are
  already seen and land under Earlier. If that sync fails (offline, signed out),
  the refresh still runs and the sync message says why. There's no background timer.
- The iCloud sign-in (CloudKit web auth token) is kept in `chrome.storage.local`
  (trusted contexts only) since 0.5.1, so it survives browser restarts and
  extension updates and reloads. Before that it was in `chrome.storage.session`,
  which both wipe, so every update needed a new sign-in; 0.5.1 moves an existing
  session token over. **Clear Royal session** or a new configuration removes it.
  When there's no sign-in, or CloudKit refuses it (`AUTHENTICATION_REQUIRED` /
  `AUTHENTICATION_FAILED`, for example once Apple expires it), sync pauses with
  changes pending and the feed page shows **Sign in to iCloud**, which signs in
  and syncs.
- Turning sync on imports this browser's library into the signed-in account
  without overwriting existing records or tombstones. Each account/container/
  environment has its own copy in this browser; another Apple Account pauses sync
  until you turn it on for that account. **Turn off sync** (or saving a new
  configuration) switches back to the local library and keeps the synced copy.
  Clearing the browser's extension data removes both.
- Verified only against `fake-cloudkit.mjs`, a test-only in-memory CloudKit
  (not loaded by the extension): in unit tests with two devices (import vs.
  tombstones, both-ways saves, same-post conflict, All refresh vs. Mark all read,
  seen union, offline, account isolation, deleted zone), and with the real
  extension in Chrome for Testing syncing to a second Node client.
- **Live (2026-11-10, Production):** after the 0.4.2 extension-ID change and a
  token whose redirect URL matches the new callback, Apple sign-in works again
  and **Turn on sync** succeeds. Zone creation, `records/changes`, and
  conditional `records/modify` against the deployed schema all work on Apple's
  servers. The owner then confirmed sync working between two browser profiles
  on the same Apple Account. Which of steps 4–7 below were covered (in
  particular the conflict and offline cases) wasn't itemized.

#### Sync live test (two browser profiles, Production)

1. **Schema (once).** Production never creates record types on its own; they
   must be made in Development and deployed. In CloudKit Console, choose
   container `iCloud.com.tinykings.Royal` → **Development** → Schema → Record
   Types, and create:
   - `RoyalSavedPost`: `postID` String, `post` String, `savedAt` String,
     `isSaved` Int(64), `schemaVersion` Int(64)
   - `RoyalSeen`: `ids` String, `sources` String, `schemaVersion` Int(64)
   - `RoyalAllSnapshot`: `snapshot` String, `schemaVersion` Int(64)

   No indexes are needed: Royal never queries, it fetches zone changes. Then
   **Deploy Schema Changes…** to Production. This only adds record types; it
   doesn't change existing records, the probe, or the TestFlight app. The
   `RoyalSync` zone is created by Royal itself. Keep the existing Production web
   API token.
2. Load `desktop/` unpacked in a second browser profile (or in both Chrome and
   Edge). The manifest key gives it the same extension ID and callback URL
   everywhere, so one token works for both.
3. In each: iCloud probe tab → Production → Save → Sign in with Apple (same
   Apple Account) → **Turn on sync**. Expect "Synced. Received …, sent …". An
   error naming a record type, or `BAD_REQUEST` on `records/modify`, means the
   schema from step 1 isn't deployed to Production yet.
4. Save a post in profile 1; in profile 2 press **Sync now** (or reopen Royal): it
   appears in Saved. Unsave it in 2; sync 1: it's gone.
5. **Refresh All** in 1, sync 2: identical All list and "Refreshed" time.
   **Mark all read** in 2, sync 1: everything is under Earlier.
6. Conflict: with both synced, unsave a post in 1 and sync; then without syncing
   2 first, save something else in 2 and toggle the same post in 2; Sync now in 2,
   then in 1. Both end with 2's last choice.
7. Offline: turn off the network, save a post, note "1 change pending"; reconnect
   and Sync now: pending returns to 0.

Report the sync status text, and service-worker console lines starting with
`[Royal sync]` (they hold counts and CloudKit error codes only, no tokens).

### Worker vs. page: what was verified

Checked on 2026-11-10 with Chrome for Testing 156 (headless, Linux), loading this
`desktop/` folder unpacked. Fake Reddit/YouTube/HN servers were mapped onto the
real hostnames (`--host-resolver-rules`). Cookies were set by visiting those
hosts as top-level pages, the same way a real login sets them:

- From **both** the service worker and the extension page, `fetch(...,
  { credentials: "include" })` to a host-permitted origin sent every unpartitioned
  cookie: `SameSite=Strict`, `Lax`, `None`, unspecified (Lax by default), and
  `HttpOnly`. Only a `Partitioned` (CHIPS) cookie was not sent. Requests had
  `Sec-Fetch-Site: none` and no `Origin` header.
- The same held with **third-party cookies blocked** (`cookie_controls_mode: 1`).
  A control confirmed the blocking was on: a YouTube iframe inside a Reddit page
  received no cookies.
- The shared `sources.js` fetched and parsed fake logged-in Reddit Best/Top, HN,
  and YouTube Subscriptions from the worker, and the list rendered in the page.
  The YouTube HTML parse (`parseYouTubeFeed`) is plain string/JSON work, so it
  needs no DOM and runs in the worker.
- A redirect from YouTube to an unpermitted host (for example
  `consent.youtube.com`) fails as `TypeError: Failed to fetch` in both contexts
  (CORS/CSP), never as a readable page. Royal reports it as "YouTube may have
  redirected to a sign-in or consent page". The host list was deliberately not
  widened to Google sign-in/consent hosts.

Since both contexts behave the same, fetching runs in the **worker**. It keeps
provider responses out of the UI, it is where the CloudKit client already
lives, and it is what a later hosted UI or bridge would need anyway. Edge was
not tested; it uses the same Chromium networking.

Live, logged out (real sites, from this Linux machine):

- Hacker News: 50 stories loaded from the worker.
- YouTube Subscriptions: `NotLoggedInError` ("YouTube session is logged out"),
  shown as "Log into YouTube in this browser".
- Reddit: HTTP 403 "blocked by network security" on
  `/subreddits/mine/subscriber.json`. Plain `curl` from the same IP gets the same
  403 even on public `.json` listings, whatever the user agent, so this network is
  blocked for anonymous JSON. It says nothing yet about a logged-in desktop session.

**Live, logged in (verified 2026-11-10 by the owner):** after logging into
reddit.com and youtube.com in the same desktop browser profile (Chrome/Edge),
Reddit Best and Top today, Hacker News, and YouTube Subscriptions and Home all
loaded in the extension. Reddit's network-security block seen above does not
apply to the logged-in desktop session's requests from the extension.

**Not yet confirmed:** the logged-out state with a real session (step 4 of the
live test), the iCloud probe re-check after the 0.2.0 update (step 5), which
browser/OS combinations beyond the owner's, and the "Site access: on click /
specific sites" path (handled by `chrome.permissions.contains`, but only covered
by unit tests).

### Live test

1. On `chrome://extensions` or `edge://extensions`, **Reload** Royal (now
   0.4.2) and accept the new site access if asked. Close old Royal tabs and
   reopen from the toolbar.
2. In normal tabs of the same browser profile, log into reddit.com and
   youtube.com. Finish any cookie/consent prompts.
3. Open Royal. All refreshes the first time. Check the Reddit (**Best**, **Top
   today**), Hacker News, and YouTube (**Subscriptions**, **Home**) tabs.
4. Save a post from All and one from a source tab; both appear in **Saved**.
   Unsave one. Close and reopen the browser: All and Saved are unchanged.
5. Switch between source tabs and refresh them, then return to All: it must not
   have changed. **Mark all read**, then **Refresh All**: only posts that arrived
   since are under New.
6. Log out of one site and **Refresh All**: that source should say which site to
   log into while keeping its previous posts, and the others still refresh.
7. Confirm the **iCloud probe** tab still signs in and reads/writes as before.

Report for each source: post count or the exact status text. Then, from the
extensions page, **Details → Inspect views: service worker → Console**, send
every line starting with `[Royal feeds]` (they contain only the source, error
class, message, and timing; no cookies or tokens), plus any red errors, such as
CSP violations (`violates the following Content Security Policy directive`),
`net::ERR_…` codes, or `Illegal invocation`. In the Network panel, the status
code of a failing `www.reddit.com` or `www.youtube.com` request is useful.
Don't export a HAR or copy request headers: they contain your session cookies.

## Apple setup (once, on the developer account)

1. Register the iCloud container `iCloud.com.tinykings.Royal` in the Apple Developer
   account for team `7F4K5N55BN`, and associate it with Royal's App ID
   `com.tinykings.Royal` with CloudKit enabled. This can be done through Apple
   Developer's Identifiers area, or Xcode's Signing & Capabilities → iCloud →
   CloudKit. Keep the existing key-value storage capability.
2. The repository now declares the CloudKit container/service entitlements and
   `RoyalCloudKitProbeContainer` in Info.plist. Debug builds select `Development`;
   Release builds select `Production` through `ROYAL_CLOUDKIT_ENVIRONMENT`.
   Automatic signing is enabled. Xcode Cloud needs a provisioning profile that
   includes this container; a signing error about iCloud entitlements means the
   App ID/container association or profile needs updating. Committing these files
   does not register a container in Apple's account.
3. In CloudKit Console's **development** schema, create `RoyalSyncProbe` with
   two String fields: `message` and `writtenAt`. Use the private database and its
   default record zone. There is no public-record sharing or query requirement.
   Deploy this schema to **production** in CloudKit Console before testing via
   TestFlight. Deployment copies the schema, not development records; create a
   fresh test message in the production environment.
4. Load this directory as an unpacked extension in Chrome/Edge's extensions
   developer mode. Click its toolbar action to open the experiment.
5. Copy the exact callback URL shown in the extension. Since 0.4.2 it is always
   `https://mddlclgijonpcbbehfggjpijpjlnakcp.chromiumapp.org/cloudkit`:
   `manifest.json` has a public `key`, which fixes the extension ID in every
   folder, profile, and Chromium browser. Before 0.4.2 the ID came from the
   folder's path, so moving or re-cloning the folder changed it and broke the
   token's redirect. The matching private key isn't needed (it's only used to
   pack a `.crx`) and isn't in the repository.
6. In CloudKit Console, create a web API token for the same container. Set its
   URL redirect/sign-in callback to that exact HTTPS address. Set **Allowed
   Origins** to **Any Domain**. Verified: Console prefixes every restricted
   domain with `https://`, so `chrome-extension://<id>` can never match and the
   token returns `AUTHENTICATION_FAILED` (HTTP 401). A web API token is not a
   secret, and private data still requires the user's Apple sign-in; the cost is
   that other sites could use the token to show sign-in for this container.
   A possible later hardening is rewriting the extension's `Origin` header to its
   `https://<extension-id>.chromiumapp.org` host and allowing only that domain;
   this is untested.
7. Enter the container identifier, web API token, and **Production** environment
   in the extension for TestFlight testing (**Development** for local Debug
   builds). These are application configuration, not an Apple password
   or server-to-server private key. Do not paste Apple credentials into Royal.

The iOS build and extension must use the same CloudKit environment. The iOS test
screen displays its configured environment. TestFlight/App Store builds use
production; changing the extension to Development cannot access their records.

## Xcode Cloud → TestFlight workflow

1. Complete the developer-account association and production schema deployment
   above. No local iOS debug install is required.
2. Push these committed changes when ready, then run your existing Xcode Cloud
   workflow with a Release archive and TestFlight distribution. No new workflow
   script, build secret, or web API token is needed in Xcode Cloud. Apple account
   provisioning and CloudKit schema setup are still required.
3. Install the **new** TestFlight build; an already-uploaded build cannot acquire
   the new test screen. Open Settings → Web Sync Experiment → Test iCloud Sync.
   It should show `iCloud.com.tinykings.Royal` and `Production`.
4. Use Production in the extension and follow the acceptance test below.

The experiment is deliberately available in both Debug and Release Settings;
general network diagnostics remain Debug-only. Release is also the App Store
configuration, so the experiment is not gated by the installation channel.

## Acceptance test

1. Sign into iCloud on the iPhone and install the new TestFlight build, or use a
   configured Xcode Debug build on a device/simulator. Open
   **Settings → Web Sync Experiment → Test iCloud Sync**. Match the extension's
   environment to the one displayed there.
2. Read the private probe (it may not exist), write `Hello from Royal iOS`.
3. In the extension, click **Sign in with Apple** and use that same Apple Account.
   Apple should return to the extension callback without a hosted page. If it
   refuses the origin/callback, record that failure before attempting a fallback.
4. Read the probe on desktop. The iOS message should appear. Write a different
   message and read again on iOS. The fixed record is `royal-sync-probe-v1`.
5. Read on both clients, write on one, and try writing from the other's stale
   version. That write must fail rather than overwrite; read again to retry.
6. Clear the Royal desktop session and sign in to a different Apple Account.
   The first user's probe must not be visible. Account changes require another
   read before writing. Clear the session on a shared computer when done.
7. Close/reopen the browser, and reload the extension: configuration and the
   iCloud sign-in remain, and sync works without signing in again (unless Apple
   has expired the token; then **Sign in to iCloud** appears).

The native probe writes only the probe record and uses revision-checked saves.
The extension's CloudKit operations are bounded to the probe and the opt-in
sync zone described under [Sync experiment](#sync-experiment). Its only other
network access is the feed hosts listed under [Feeds](#feeds); it has no
`cookies` permission, content scripts, or external messaging. Its one
`declarativeNetRequest` rule only sets the referrer on YouTube embeds its own page
loads.
User tokens never return to the tab UI or console; the worker serializes requests
and adopts rotated web auth tokens. Configuration changes clear the local session.
“Clear Royal session” clears local credentials, not the global Apple login.

## If extension-only authentication fails

### Apple login completes, then "Apple sign-in didn't come back"

Apple redirected to a different callback than this extension's. Set the token's
redirect URL to the callback shown in the iCloud probe tab (see setup step 5).
Version 0.4.2 fixed the extension ID, so this changes once from older versions;
before that, the ID followed the folder path. Older versions reported this only
as "Operation failed".

### Immediate NETWORK_ERROR before an Apple login window

Reload Royal on `edge://extensions` or `chrome://extensions` after updating these
files, close its old tab, and reopen it from the toolbar. Version 0.1.1 corrects
the identity request to Apple's documented `public/users/caller` endpoint;
probe reads/writes continue to use the private database. It also separates
network failures from timeouts and actual CloudKit HTTP responses.
Version 0.1.2 fixes the cause of the `NETWORK_ERROR`: the client called the
browser's native `fetch` as a method of its own object, and Chromium refuses that
call ("Illegal invocation") before sending any request. Node's `fetch` accepts it,
so the mocked tests missed it. A regression test now covers this.

Click **Check connection**. This uses an intentionally invalid token; HTTP 401
(`AUTHENTICATION_FAILED`) is an expected successful reachability check. It does
not validate your configured token or clear an existing sign-in session.

- If host access is missing, allow Royal access to `api.apple-cloudkit.com` in
  the browser's extension Details and retry.
- If the check reaches CloudKit but Sign in fails, verify that your real token
  matches the container/environment and allowed extension origin. An HTTP error
  provides more evidence than a browser fetch failure; don't change callback
  settings at random before Apple login even opens.
- If there is still no HTTP response, open Royal's **service worker** inspector
  from its extensions-page Details. In its Console/Network panel, retry Sign in
  and note the browser error code (for example `net::ERR_BLOCKED_BY_CLIENT`, a
  CSP error, or a DNS/TLS error). Requests contain tokens in their query strings:
  share only the error code/status, not complete request URLs or an exported HAR.

`NETWORK_ERROR` alone cannot identify an origin, connectivity, browser policy, or
redirect failure. The local tests mock responses; live login was verified later
(see Status). The connection check neither relaxes allowed origins nor follows
credential-bearing requests to other hosts.

### Hosted fallback

Use a small static HTTPS page for CloudKit authentication/the UI, with the
extension supplying authenticated provider requests. This is a fallback, not an
existing deployment. Keep callback/bridge origins explicit, and validate sender
and login-response binding before transferring any session information. No custom
database or application server would be needed; CloudKit would supply storage.

## After the probe passes

- Add the extension's feed adapters with explicit Reddit/YouTube permissions and
  desktop logins, reusing the root `sources.js`. Prove authenticated fetching.
  **Done in 0.2.0:** see [Feeds](#feeds). Authenticated fetching from the
  extension worker was verified live with desktop logins on 2026-11-10.
- Keep All as a separate ordered snapshot, replaced only on explicit refresh.
  Individual source refreshes must not mutate it. Sync seen/unseen changes and
  per-post saved/unsaved records independently, with durable offline operations.
- Add revision/conflict handling, account isolation, resumable save migration,
  refresh-on-resume checks, and opt-in sync settings before enabling real data.
- Replace the probe with that integration only after native/web compatibility is
  proven. Do not treat the probe's single String message as a production sync schema.

## Next

Saved posts and seen posts sync live between iOS and desktop (tested on real
devices, 2026-11-11). Remaining, roughly in order:

1. **Sync edge cases, live.** Concurrent saves on both sides, offline unsave then
   reconnect, same-post conflict, Apple Account switch, an interrupted first
   import, and saves above the old key-value size limit.
2. **Extension UI.** First pass done in 0.5.0 (see
   [Page design and video](#page-design-and-video-050)). Remaining: check it
   with real feeds, Settings-like choices (card/list per source, open link vs.
   comments), NSFW handling for saved posts, and the iCloud tab's design.
3. **Match Hacker News's load count to iOS.** In All, iOS shows Hacker News's
   first page of 30 stories (`FeedSession.hackerNewsPageSize`, then more on
   scrolling), but the desktop fetches 50 (`FEED_LIMIT` in `feeds.mjs`). So after
   refreshing and marking all read on iOS, a desktop Refresh All shows stories
   31–50 as New though they're old, unless they were scrolled to on iOS. Give
   Hacker News its own limit of 30 in `SOURCES.hn` (Reddit and YouTube stay at 50;
   iOS fetches 100 of those, which only means more of them count as seen), and
   add a test for it in `feeds.test.mjs`.
4. **All snapshot on iOS.** Read and write `RoyalAllSnapshot` so a refresh or
   Mark all read on one device shows on the other. Leaning towards not doing
   it: seen sync already keeps posts one device showed from coming back as New
   on the other. Adopting it would make iOS's All a stored snapshot (refreshing
   the YouTube tab would no longer change All), and iOS would have to split it
   with the snapshot's own `previouslySeen`/`previousRefresh` and YouTube list,
   not its merged seen ids, or everything the desktop just showed would land
   under Earlier on iOS unread.
5. **Out of experiment.** Move the toggle out of Web Sync Experiment, retire the
   probe, and decide when iOS stops mirroring saves into iCloud key-value storage.
6. **Policy and polish.** Retention for saved snapshots of content deleted
   upstream (Reddit's terms), and extension packaging.

## Local checks

Run `node --test` at the repository root. It also checks that
`desktop/sources.js` matches the root `sources.js`, and that feed code calls
`fetch` as a plain function. Tests mock CloudKit protocol behavior;
they cannot establish Apple login compatibility, provisioning, or record access.
This workspace is Linux and has no Xcode/iOS Simulator, so native compilation
requires a Mac; the phone acceptance test can use Xcode Cloud
and TestFlight instead of a local Xcode install.

References: [Apple web authentication](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html),
[record lookup](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/LookupRecords.html),
[record writes](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ModifyRecords.html),
[Chrome identity callbacks](https://developer.chrome.com/docs/extensions/reference/api/identity),
[remote-code restrictions](https://developer.chrome.com/docs/extensions/develop/migrate/remote-hosted-code).
Identity endpoint: [Apple's users/caller reference](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/FetchCurrentUserIdentity.html).
See also [iCloud configuration](https://developer.apple.com/documentation/xcode/configuring-icloud-services/),
[schema deployment](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema),
and [CloudKit testing environments](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitQuickStart/TestingYourApp/TestingYourApp.html).
