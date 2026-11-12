# App Review notes for Royal 1.0

Paste the block below into App Store Connect > App Review Information > Notes
(limit 4,000 characters). Fill in the [brackets] first. Put the Reddit demo login
in the "Sign-in required" username/password fields as well.

---

SCREEN RECORDING
[Link to recording, e.g. an unlisted video or iCloud link — or "attached below"]
Recorded on [iPhone model], iOS [version], starting from launch.

1. PURPOSE AND AUDIENCE
Royal is a reader for people who follow Reddit, RSS feeds, and YouTube and want one place to catch up. It shows posts from the subreddits a user already follows, items from RSS feeds the user adds (by default Hacker News stories, Krebs on Security, Pitchfork's Best New Albums and The Verge), and new uploads from the user's YouTube subscriptions, in separate tabs and in a combined "All" feed that marks what is new since the last visit. Users can save posts for later (synced through the user's private iCloud database) and play YouTube videos in the app. It is for adults who already use these services; it has no algorithmic recommendations, ads, or tracking.

2. HOW TO USE / DEMO ACCOUNTS
- RSS works with no login: turn on RSS in Settings > Sources, then open the RSS tab. Its list button, or Settings > RSS > Feeds, looks up and adds feeds from a feed's or website's address, removes them, and imports or exports OPML files.
- Reddit: Settings tab > Reddit > Account. Log in on Reddit's own login page with:
  Username: [demo username]
  Password: [demo password]
  (Use username/password. "Continue with Google" is blocked by Google inside embedded web views.) This account follows several subreddits, so the Reddit and All tabs fill in.
- YouTube: Settings tab > YouTube > Account. Log in on Google's own sign-in page with:
  Email: [demo Google account]
  Password: [demo password]
  [If Google asks for verification, use: ... / contact: phone or email]
  This account subscribes to several channels, so the YouTube tab fills in.
- Tap a Reddit post to open its link or comments, or an RSS item to read its description or open its link (each choosable in Settings); long-press for the other, plus Save. Tap the heart to save; see them via the All tab's header menu > Saved. Tap the current tab to scroll to the top, and again to refresh.

ACCOUNTS: Royal has no accounts of its own and no server. Logging in happens on Reddit's and Google's own web pages inside the app; Royal never sees or stores passwords. Settings has a Log Out button for each service, which clears that service's session from the app. Account creation and deletion for Reddit and Google are handled by those services, not by Royal.

USER-GENERATED CONTENT: Royal does not host or let users post content of its own. It shows content from Reddit, the RSS feeds the user chooses, and YouTube. NSFW and pinned Reddit posts are always excluded, along with NSFW subreddits. Reporting and blocking use each service's own tools: Reddit posts and RSS items open on their own sites (Reddit opens logged in), where users can report posts and block users; [describe any in-app hide/report/block added for this build].

3. EXTERNAL SERVICES
- Reddit (reddit.com): post listings for the user's followed subreddits, with the user's own login.
- RSS feeds the user adds, fetched from each feed's own site with no cookies (by default hnrss.org, krebsonsecurity.com, pitchfork.com and theverge.com).
- YouTube / Google (youtube.com, accounts.google.com): the user's subscription feed and sign-in; videos play through YouTube's embedded player.
- Apple CloudKit (the user's private iCloud database): syncs saved posts, and which posts the All feed has shown, between the user's devices, and shows saved posts on the Royal Saved website (royal.tinyk.ing/saved) when the user signs in there with Apple. It uses the Apple Account signed in to iCloud; Settings > Sync shows its state. Data stays in the user's own iCloud account; there is no Royal server.
No analytics, ads, AI services, payment processors, or backend of our own. There are no in-app purchases.

4. REGIONAL DIFFERENCES
The app works the same in all regions. Content comes from Reddit, RSS feeds, and YouTube, so it is unavailable where those services are blocked, and in some regions (e.g. the EU) Google may show a consent prompt during YouTube sign-in. The interface is English only.

5. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Royal is not in a regulated industry. It shows third-party content the way a browser does: each user sees content from their own accounts, signed in with their own credentials, with links back to the original posts. It does not download, re-host, or redistribute that content. YouTube videos play only through YouTube's official embedded player.

Privacy policy: https://tinykings.github.io/Royal-iOS/#privacy
Source code: https://github.com/tinykings/Royal-iOS
