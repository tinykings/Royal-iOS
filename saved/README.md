# Royal Saved

A website at **https://royal.tinyk.ing/saved/** showing the posts saved with ♥ in Royal on
iPhone. Sign in with Apple; there's no Royal
server. Saved posts sync through Apple's CloudKit Web Services API with your private
iCloud database, the same `RoyalSavedPost` records iOS writes
([sync schema](https://github.com/tinykings/Royal-iOS/blob/main/docs/sync-schema.md)).
It never fetches Reddit or YouTube, and it never reads or writes the seen or All
records.

You can open a post, play a YouTube video on the page, and unsave (with Undo). An
unsave syncs back to iOS as a tombstone, like everywhere else.

## Publishing

Every push to `main` that touches `saved/` or `docs/index.html` runs
`.github/workflows/pages.yml`: it runs `node --test`, then publishes one GitHub
Pages site at `royal.tinyk.ing`, with the landing page and privacy policy
(`docs/index.html`) at `/` and this site at `/saved/`. The old
`tinykings.github.io/Royal-iOS/` addresses redirect there.

### Setup (once)

1. **Old repository:** in `Royal-Saved`'s **Settings → Pages**, remove the custom
   domain and unpublish the site (then archive the repository), so the hostname is
   free for this one.
2. **GitHub:** in this repository's **Settings → Pages**, set **Source** to
   *GitHub Actions* and the custom domain to `royal.tinyk.ing`, and turn on
   **Enforce HTTPS** when the certificate is ready. The DNS `CNAME` record for
   `royal` on `tinyk.ing` already points to `tinykings.github.io`.
3. **CloudKit Console** (container `iCloud.com.tinykings.Royal`, Production): on
   the website's web API token, change the sign-in callback (**URL Redirect**) to
   `https://royal.tinyk.ing/saved/`. The allowed origin stays `royal.tinyk.ing`.

The token is `SITE_CLOUDKIT.apiToken` in `site.mjs`. The record types are already
deployed to Production for iOS.

## Security

- **Its own origin.** The site keeps your CloudKit sign-in token in this origin's
  `localStorage`. It's on its own hostname because every `tinykings.github.io`
  project page shares one origin and could read it. The only other page on
  `royal.tinyk.ing` is Royal's own landing page from this repository.
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
- `shared/`: CloudKit client, library, sync and conflict rules, preferences,
  stylesheet, tested in `tests/` against the fake CloudKit server in
  `tests/fake-cloudkit.mjs`.

## When it syncs

When the page opens, when it comes back into view, every two minutes while it's
showing, and 1.5 s after an unsave. Tabs take turns with the library and CloudKit
(Web Locks), and other open tabs redraw when one changes it. If Apple expires the
sign-in, the list stays and changes stay pending until you sign in again.

## Testing

```
node --test
```

Run it from the repository root. To try
the page locally, serve the repository root (for example `python3 -m http.server
8123`) and open `/saved/`. Apple's sign-in
always returns to `https://royal.tinyk.ing/saved/`, so sign-in only completes on
the real site.
