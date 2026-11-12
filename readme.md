# Royal

Website: <https://royal.tinyk.ing/> · Saved posts on the web: <https://royal.tinyk.ing/saved/> ([`saved/`](saved/README.md))

iOS app combining Reddit, RSS feeds, and your YouTube subscriptions in one feed. SwiftUI, no third-party dependencies.

## Features

- Tabs for RSS, Reddit, a combined **All** feed, YouTube, and settings. Each source can be turned off in Settings. Posts can be saved for later.
- **RSS**: any RSS 2.0, RSS 1.0 or Atom feeds, newest first, as cards with each item's image from the feed, or as a list. New installs start with Hacker News stories over 150 points ([hnrss](https://hnrss.org/)), Krebs on Security, Pitchfork's Best New Albums and The Verge. Manage feeds from the tab's list button or Settings › RSS › Feeds: paste a feed's address, or a website's to look up the feeds it offers; swipe to remove, drag to reorder; import or export an OPML file. Tapping an item shows its description from the feed in the app, or opens its link (Settings); swipe right or press and hold for the other.
- **Reddit**: **Best** or **Top** (today), from the subreddits you follow only, or **Top** (today) from one of them picked from the menu at the top.
- **YouTube**: your **Subscriptions** or the **Recommended** videos from your Home page, with any that are new since the last refresh first.
- Uses your Reddit and YouTube logins from in-app sign-in pages—no API keys or OAuth setup. Reddit links open with that login, so you can vote and reply.
- Plays YouTube videos in-app.
- **iCloud sync**: saved posts, and the posts the All feed has shown, sync through your private iCloud database (CloudKit) between your devices, and saved posts appear on [Royal Saved](saved/README.md) on the web ([format](docs/sync-schema.md)). It uses the Apple Account signed in to iCloud; until one is, saves stay on the device.
- Caps Reddit posts at five per subreddit, except when viewing a single subreddit; excludes pinned posts, and NSFW posts unless turned on in Settings.
- The All feed shows posts new since the previous refresh. Pull up at the end to mark them read; pull up the empty feed to look back through earlier posts. Feeds refresh on their own after 15 minutes away; tap the current tab to jump to the top.

## Build

Requires Xcode 16 or later; targets iOS 17.0+.

```sh
git clone git@github.com:tinykings/Royal-iOS.git
cd Royal-iOS
open Royal.xcodeproj
```

Select your signing team, then build and run on a simulator or device.

## How it works

Fetching and parsing lives in `sources.js`. A build phase copies it into the app bundle, and `FeedSession` runs it in a hidden `WKWebView`, routing its `fetch()` calls through `URLSession` with the web view's login cookies. RSS feeds can be on any site, so they are fetched natively in `RSSFeeds.swift` instead, with no cookies, and parsed with `XMLParser`; descriptions show in a web view with scripts off. Requests go directly to Reddit, YouTube, and each feed's own site; there is no backend.

RSS replaced the Hacker News tab. Stored `hn` sources, settings and saved posts read as RSS, and hnrss items keep their Hacker News ids (`hn_<id>`), so earlier saves and seen posts carry over.

YouTube access relies on undocumented page data and may break when YouTube changes its layout.

## Configuration

Edit `CONFIG` in `sources.js`:

| Setting | Default | Purpose |
| --- | --- | --- |
| `totalItems` | `100` | Maximum items per feed |
| `redditTimeWindow` | `"day"` | Reddit Top window when none is given (the app always asks for `day`) |
| `maxPerSubreddit` | `5` | Maximum posts selected per subreddit |

The RSS feeds a new install starts with are `RSSFeed.defaults` in `Royal/RSSFeeds.swift`. The RSS tab shows the newest 100 items across all feeds.

## Tests

`sources.js` and the Royal Saved website have Node tests that mock network requests. Run with Node.js 22 or later:

```sh
node --test
```

## Project files

| Path | Purpose |
| --- | --- |
| `Royal/` | SwiftUI app sources |
| `Royal.xcodeproj` | Xcode project |
| `Info.plist`, `Royal.entitlements` | App configuration |
| `sources.js` | Reddit and YouTube fetching and normalization |
| `Royal/RSSFeeds.swift` | RSS and Atom fetching and parsing, OPML, and the feed list |
| `sources.test.mjs`, `youtube.test.mjs` | Tests for `sources.js` |
