# Agent workflow

- Commit your changes when a task is done, with a clear message. Do not push.
- After changing the app, if an iOS Simulator is booted (`xcrun simctl list devices booted`),
  rebuild Royal for it and launch the app there so the change can be tested right away:

  ```
  xcodebuild -project Royal.xcodeproj -scheme Royal -destination 'id=<booted UDID>' build
  ```

  Then install and launch the built `Royal.app` on that simulator.
- Run `node --test` after changing `sources.js`.
