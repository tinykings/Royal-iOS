# Royal

Website: <https://tinykings.github.io/Royal-iOS/>

iOS app combining Reddit, Hacker News, and your YouTube subscriptions in one feed. SwiftUI, no third-party dependencies.

## Features

- Tabs for Hacker News, Reddit, a combined **All** feed, YouTube, and settings. Posts can be saved for later.
- Reddit sort: **Best** or **Top** (today), from the subreddits you follow only, or **Top** (today) from one of them picked from the menu at the top. Hacker News: **Top** or **New**. YouTube: your **Subscriptions** or the **Recommended** videos from your Home page.
- Uses your Reddit and YouTube logins from in-app sign-in pages—no API keys or OAuth setup. Reddit links open with that login, so you can vote and reply.
- Plays YouTube videos in-app.
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

Fetching and parsing lives in `sources.js`. A build phase copies it into the app bundle, and `FeedSession` runs it in a hidden `WKWebView`, routing its `fetch()` calls through `URLSession` with the web view's login cookies. Requests go directly to Reddit, Hacker News, and YouTube; there is no backend.

YouTube access relies on undocumented page data and may break when YouTube changes its layout.

## Configuration

Edit `CONFIG` in `sources.js`:

| Setting | Default | Purpose |
| --- | --- | --- |
| `totalItems` | `100` | Maximum items per feed |
| `redditTimeWindow` | `"day"` | Reddit Top window when none is given (the app always asks for `day`) |
| `maxPerSubreddit` | `5` | Maximum posts selected per subreddit |

## Tests

`sources.js` has Node tests that mock network requests. Run with Node.js 22 or later:

```sh
node --test
```

## Project files

| Path | Purpose |
| --- | --- |
| `Royal/` | SwiftUI app sources |
| `Royal.xcodeproj` | Xcode project |
| `Info.plist`, `Royal.entitlements` | App configuration |
| `sources.js` | Reddit, Hacker News, and YouTube fetching and normalization |
| `sources.test.mjs`, `youtube.test.mjs` | Tests for `sources.js` |
