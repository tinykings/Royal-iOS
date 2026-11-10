# CloudKit authentication and private-record spike

This unpacked Chromium extension opens a full tab with a CloudKit sign-in and a
small private read/write probe. It uses Apple's HTTP endpoints directly; it does
not load a remote JavaScript SDK or require a hosted website.

**Status:** implementation with mocked protocol tests, not a proven live Apple
integration. No CloudKit container or token was provisioned during development.
It does not yet fetch desktop feeds, migrate saves, or sync timeline/seen/saved
data. Existing iOS storage remains authoritative and unchanged.

## Apple setup (once, on the developer account)

1. In Xcode, enable iCloud → CloudKit on Royal and create/associate a container,
   for example `iCloud.com.tinykings.Royal`. Keep the existing key-value storage
   entitlement. Do not enable production sync or remove existing saves.
2. Add `RoyalCloudKitProbeContainer` (String, matching the container identifier)
   to the debug build's Info.plist. The debug probe does not construct a
   `CKContainer` until this key is present and a test button is tapped. The
   CloudKit capability/provisioning must be set up before using those buttons.
   The repository deliberately does not alter signing entitlements before the
   container exists in your Apple account.
3. In CloudKit Console's **development** schema, create `RoyalSyncProbe` with
   two String fields: `message` and `writtenAt`. Use the private database and its
   default record zone. There is no public-record sharing or query requirement.
4. Load this directory as an unpacked extension in Chrome/Edge's extensions
   developer mode. Click its toolbar action to open the experiment.
5. Copy the exact callback URL shown in the extension, of the form
   `https://<extension-id>.chromiumapp.org/cloudkit`.
6. In CloudKit Console, create a web API token for the same container. Set its
   URL redirect/sign-in callback to that exact HTTPS address. Configure allowed
   origins for the displayed extension origin if Console accepts it. Origin
   support and the callback behavior are **the experiment**, not verified facts.
   Do not relax restrictions to all websites just to get the test working.
7. Enter the container identifier, web API token, and `development` environment
   in the extension. These are application configuration, not an Apple password
   or server-to-server private key. Do not paste Apple credentials into Royal.

Development Xcode builds and the extension must use the same CloudKit environment.
TestFlight/App Store builds use production; do not switch the spike to production
without intentionally deploying the schema and checking the native entitlement.

## Acceptance test

1. Sign into iCloud on the iPhone/simulator. Build Royal on a Mac with Xcode, then
   open **Settings → Web Sync Experiment → Test iCloud Sync** in the debug app.
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
7. Close/reopen the browser: public container configuration remains, but Royal's
   web auth token is session-only and another Apple sign-in may be needed.

The native probe writes only the probe record, uses revision-checked saves, and
is excluded from Release. The extension is also bounded to the probe operations;
it has no Reddit, YouTube, cookies, content-script, or external messaging access.
User tokens never return to the tab UI or console; the worker serializes requests
and adopts rotated web auth tokens. Configuration changes clear the local session.
“Clear Royal session” clears local credentials, not the global Apple login.

## If extension-only authentication fails

Use a small static HTTPS page for CloudKit authentication/the UI, with the
extension supplying authenticated provider requests. This is a fallback, not an
existing deployment. Keep callback/bridge origins explicit, and validate sender
and login-response binding before transferring any session information. No custom
database or application server would be needed; CloudKit would supply storage.

## After the probe passes

- Add the extension's feed adapters with explicit Reddit/YouTube permissions and
  desktop logins, reusing the root `sources.js`. Prove authenticated fetching.
- Keep All as a separate ordered snapshot, replaced only on explicit refresh.
  Individual source refreshes must not mutate it. Sync seen/unseen changes and
  per-post saved/unsaved records independently, with durable offline operations.
- Add revision/conflict handling, account isolation, resumable save migration,
  refresh-on-resume checks, and opt-in sync settings before enabling real data.
- Replace the probe with that integration only after native/web compatibility is
  proven. Do not treat the probe's single String message as a production sync schema.

## Local checks

Run `node --test` at the repository root. Tests mock CloudKit protocol behavior;
they cannot establish Apple login compatibility, provisioning, or record access.
This workspace is Linux and has no Xcode/iOS Simulator, so native compilation and
the acceptance test require a Mac.

References: [Apple web authentication](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html),
[record lookup](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/LookupRecords.html),
[record writes](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/ModifyRecords.html),
[Chrome identity callbacks](https://developer.chrome.com/docs/extensions/reference/api/identity),
[remote-code restrictions](https://developer.chrome.com/docs/extensions/develop/migrate/remote-hosted-code).
