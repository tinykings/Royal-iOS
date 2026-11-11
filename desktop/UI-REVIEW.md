# Royal Chrome extension — UI review (2026-11-11)

Fixes and improvements to the desktop extension's UI (`desktop/`). Line numbers
are as of commit `b9bfc1e`, so check them before editing.

## How the review was done

Chrome won't let automation open `chrome-extension://` pages, so the review ran
`desktop/index.html` from a plain local server, with a fake `window.chrome`
loaded before `feeds-ui.mjs`. The fake answered `library`, `sync`,
`refreshAll`, `markAllRead`, `setSaved`, `subreddits` and `feed` with made-up
posts. The window was ~1400px wide, in dark mode. Narrow widths were checked
with a 380px `<iframe>`.

To reproduce:
1. Copy `index.html`, `style.css`, `feeds-ui.mjs` and `preferences.mjs` to a
   scratch folder.
2. Add `<script src="stub.js"></script>` before the stylesheet. `stub.js`
   defines `chrome.storage.local` get/set, `chrome.storage.onChanged`,
   `chrome.runtime.onMessage` and `chrome.runtime.sendMessage`, the last one
   returning library/feed results in the shapes `feeds-ui.mjs` expects.
3. Run `python3 -m http.server`.

Not covered: real Reddit/YouTube/iCloud data and Light mode.

## Issues (likely bugs), by priority

### 1. Tab bar is clipped in narrow windows
- `style.css:51` (`nav.tabs` … `overflow-x: auto; scrollbar-width: none`).
- At 380px the tabs stop at "Hacker" and nothing shows that they scroll.
  A vertical mouse wheel doesn't scroll them, so Saved and Settings are hard
  to reach.
- Fix options: an edge fade (mask-image) that shows there's more, wrapping
  the tabs onto a second row under the title below ~520px, or putting the
  last few tabs in a menu.
- Done when: every tab can be reached with a mouse at 360px wide, with no
  horizontal page scroll.

### 2. NSFW images aren't blurred
- `feeds-ui.mjs` `renderPost` (~line 160) and `media()` (~line 132).
  `post.nsfw` only adds "NSFW" to the details line (~line 181).
- Blur NSFW media (e.g. `filter: blur(32px)` plus a "Show" overlay) until
  it's clicked. Optionally add a Settings toggle stored with the other
  preferences (`preferences.mjs`: add it to `DEFAULT_PREFERENCES` and
  `CHOICES`, and update `preferences.test.mjs`).

### 3. Docked player is wider than the feed column
- `style.css:155`: `#player { … margin: 16px -16px 0; }`.
- The player sticks out 16px past the cards on both sides. In the compact
  player the video's left edge doesn't line up with the posts.
- Fix: match the card column (margin `16px 0 0`, plus a matching
  `border-radius` / clipping if it should look like a card), or make the
  header and the cards full-bleed too. Check both full and compact
  (`#player.compact`, `style.css:167-175`).

### 4. Error message in All runs together
- `feeds-ui.mjs` ~lines 252-258 (`#all-problems`) and `renderProblem`
  (~line 218). Styling is at `style.css:69`
  (`.feed-status.problem, .problems`).
- Currently shows as a bulleted, all-bold line: "Reddit: Not logged in to
  Reddit. Open www.reddit.com Showing its posts from the previous refresh,
  if any." There's no punctuation or spacing between the link and
  "Showing".
- Fix: show it as a warning box (no list bullet, normal weight, source name
  in bold), e.g. "**Reddit** isn't signed in — [Sign in to Reddit] ·
  Showing posts from the last refresh."

### 5. Closing the player moves the page under the mouse
- `closePlayer` / `keepInPlace` in `feeds-ui.mjs` (~lines 82-103), plus
  `rerender()` when `listWhilePlaying` is on.
- Closing switches the feeds from list rows back to cards and the page
  jumps, so whatever is under the pointer changes. A quick second click
  opened a post during the review (three tabs opened by accident).
- Fix ideas: keep the close button or the playing post fixed under the
  pointer, or briefly ignore clicks on posts (~300ms) after the layout
  changes.

### 6. Title styles differ in mixed feeds
- `style.css:94` (`.post.card .title { font-size: 17px; font-weight: 600 }`)
  versus row titles (16px, regular).
- Reddit text posts with no image are cards with no media, so in All a
  bold 17px title sits next to Hacker News's regular 16px one.
- Fix: show image-less Reddit posts as rows (e.g. in `layoutFor` or
  `renderPost`), or use one title style for both.

## UI recommendations

- **Make earlier posts look read.** After "Show N earlier posts" (`#all-seen`,
  `feeds-ui.mjs` ~line 242) they look exactly like new posts. Dim them a
  little (`opacity: .75`, muted title) or always show them as rows.
- **Empty space in the compact player.** The title sits at the top and the
  area below "Open on YouTube" is blank (`#player.compact .player-bar`,
  `style.css:169-175`). Centre the content vertically or add the channel and
  age there.
- **Shorten the Settings copy.** The iCloud Sync section (`index.html:59-64`)
  is two dense paragraphs plus a hint. Suggested: "Sync saved and seen posts
  with Royal on iPhone and your other browsers. Sign in with the same Apple
  Account as your iPhone." Put the rest in a `<details>` titled "How sync
  works".
- **Checkbox placement in Settings.** "Show list view when playing video"
  (`index.html:72`, `label.toggle`) has its checkbox on the left; every other
  setting has its control on the right. Use a switch on the right to match
  iOS.
- **Saved is bare.** Only "N saved" and a list. Consider filtering by source
  (chips) or a search box.
- **Status lines are faint.** `.feed-status` is 13px muted (`style.css:68`).
  On source tabs, "3 posts" adds little; show "Updated 2m ago" instead, or
  drop it.
- **Keyboard support for tabs.** `nav.tabs` buttons have `role="tab"` but
  don't move with the arrow keys or use roving `tabindex`, and the panels
  lack `aria-labelledby` and the buttons lack `aria-controls`
  (`index.html:15-22`, `show()` in `feeds-ui.mjs` ~line 406).
- **The like button is hidden until hover.** `button.save { opacity: 0 }`
  (`style.css:136`) makes saving invisible to new users. Make it always
  faintly visible (e.g. `.25`), brighter on hover.

## Keep as is

The colour scheme, the gold "Earlier" divider, tall images trimmed to a
square on a blurred copy of themselves, and keeping the clicked post in
place when the player opens.

## Project rules (from AGENTS.md)

- Commit each finished task with a clear message. Do not push.
- Run `node --test` after changing `sources.js`. Also run the
  `desktop/*.test.mjs` suites if you change `preferences.mjs` or other
  modules.
- These are extension-only changes, so no iOS simulator rebuild is needed
  unless the app itself changes.
