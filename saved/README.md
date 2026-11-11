# Royal Saved

A website at **https://royal.tinyk.ing/** showing the posts saved with ♥ in Royal on
iPhone (and the Royal desktop extension). Sign in with Apple; there's no Royal
server. Saved posts sync through Apple's CloudKit Web Services API with your private
iCloud database, the same `RoyalSavedPost` records iOS writes
([sync schema](https://github.com/tinykings/Royal-iOS/blob/main/docs/sync-schema.md)).
It never fetches Reddit or YouTube, and it never reads or writes the seen or All
records.

You can open a post, play a YouTube video on the page, and unsave (with Undo). An
unsave syncs back to iOS as a tombstone, like everywhere else.

## Setup (once)

1. **DNS:** add a `CNAME` record for `royal` on `tinyk.ing` pointing to
   `tinykings.github.io`.
2. **GitHub:** push this repository (public), then in **Settings → Pages**
   choose *Deploy from a branch*, `main`, `/ (root)`. The `CNAME` file sets the
   custom domain. When the certificate is ready, turn on **Enforce HTTPS**. In
   your account's **Settings → Pages**, verify `tinyk.ing` so no one else can claim
   the hostname on GitHub Pages.
3. **CloudKit Console** (container `iCloud.com.tinykings.Royal`, Production):
   create a new web API token.
   - Sign-in callback: **URL Redirect**, `https://royal.tinyk.ing/`
   - Allowed origins: **specific domain**, `royal.tinyk.ing`
4. Put the token in `SITE_CLOUDKIT.apiToken` in `site.mjs`, commit, and push.

The record types are already deployed to Production for iOS and the extension.

## Security

- **Its own origin.** The site keeps your CloudKit sign-in token in this origin's
  `localStorage`. It's on its own hostname because every `tinykings.github.io`
  project page shares one origin and could read it.
- **Content-Security-Policy** (a `<meta>` tag, as GitHub Pages can't send headers):
  scripts and styles from this site only, connections to `api.apple-cloudkit.com`
  only, frames from `www.youtube.com` only, and Trusted Types so nothing can be
  parsed as HTML. Post titles come from Reddit and YouTube users, so they're only
  ever set as text, and links are limited to http(s) (`shared/library.mjs`).
- **No framing.** `frame-ancestors` can't be set from a `<meta>` tag, so the page
  stays hidden unless it is the top window.
- **Sign-in callback.** Apple returns the token in the address
  (`?ckWebAuthToken=…`). The page removes it from the address bar immediately and
  accepts it only if this tab started a sign-in in the last 15 minutes, so a link
  carrying someone else's token can't sign you in to their account. The request
  carrying it does reach GitHub's servers, which already serve the site's code.
- **No third-party code** at runtime; everything is in this repository. Anyone who
  can push to `main` controls the site, so keep two-factor authentication on the
  GitHub account.
- **Sign out** removes the token and this browser's copy of your saved posts (they
  stay in iCloud). Use it on a shared computer.

## Files

- `index.html`, `app.mjs`, `site.css`: the page.
- `site.mjs`: storage, Apple sign-in and sync, tested in `tests/site.test.mjs`.
- `shared/`: byte-for-byte copies of the extension's modules from
  [Royal-iOS](https://github.com/tinykings/Royal-iOS) `desktop/`: CloudKit client,
  library, sync and conflict rules, preferences, stylesheet. Don't edit them here.
  After they change there, run `scripts/update-shared.sh` (it reads
  `../Royal-iOS/desktop` by default), then `node --test`. The tests fail if the
  copies differ from a sibling `Royal-iOS` checkout.

## When it syncs

When the page opens, when it comes back into view, every two minutes while it's
showing, and 1.5 s after an unsave. Tabs take turns with the library and CloudKit
(Web Locks), and other open tabs redraw when one changes it. If Apple expires the
sign-in, the list stays and changes stay pending until you sign in again.

## Testing

```
node --test
```

To try the page locally, serve this folder (for example
`python3 -m http.server 8123`). Apple's sign-in always returns to
`https://royal.tinyk.ing/`, so sign-in only completes on the real site.
