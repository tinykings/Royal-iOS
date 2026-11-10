# CloudKit authentication and private-record spike

This unpacked Chromium extension opens a full tab with a CloudKit sign-in and a
small private read/write probe. It uses Apple's HTTP endpoints directly; it does
not load a remote JavaScript SDK or require a hosted website.

**Status:** verified live on 2026-11-10 in the Production environment. Apple
sign-in completed inside the extension (no hosted page), and the private probe
record synced both ways between the extension and a TestFlight iOS build. This
needs a web API token whose Allowed Origins is Any Domain (see setup step 6).
It does not yet fetch desktop feeds, migrate saves, or sync timeline/seen/saved
data. Existing iOS storage remains authoritative and unchanged.

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
5. Copy the exact callback URL shown in the extension, of the form
   `https://<extension-id>.chromiumapp.org/cloudkit`.
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
7. Close/reopen the browser: public container configuration remains, but Royal's
   web auth token is session-only and another Apple sign-in may be needed.

The native probe writes only the probe record and uses revision-checked saves.
The extension is also bounded to the probe operations;
it has no Reddit, YouTube, cookies, content-script, or external messaging access.
User tokens never return to the tab UI or console; the worker serializes requests
and adopts rotated web auth tokens. Configuration changes clear the local session.
“Clear Royal session” clears local credentials, not the global Apple login.

## If extension-only authentication fails

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
