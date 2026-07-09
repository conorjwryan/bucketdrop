# Battery optimisations

ShareMaster should be effectively idle when the macOS app is open but not focused, as long as it is not actively uploading or downloading. macOS already has App Nap, but App Nap works best when the app does not keep scheduling timers, polling, or network requests while it is inactive. The macOS target therefore treats passive browsing/sync/preview work as foreground-only.

## macOS inactive behaviour

When ShareMaster receives `NSApplication.didResignActiveNotification`, the popover content marks itself inactive, cancels the current foreground list task, clears the loading spinner, and stops passive work. When the app becomes active again, it refreshes config and starts a new foreground listing for the current view.

The specific macOS changes live in `ShareMaster/ContentView.swift`:

- `ContentView` tracks `isAppActive = NSApp.isActive` and a cancellable `listTask`.
- There is no periodic iCloud Keychain sync poll. `ShareMasterApp.showPopover()` pulls the latest cloud config whenever the menu-bar item opens, and `ContentView`/`SettingsView` also refresh when the app becomes active.
- Browse and Recent (All) reloads go through `startForegroundReload()` / `startForegroundBrowseLoad()`, which cancel any previous listing and refuse to start a new one unless `NSApp.isActive`.
- `loadBrowse()` and `loadRecentAll()` guard against inactive/stale completions before updating UI state, so a request that finishes after focus is lost does not continue repainting the popover.
- `CachedAsyncImage` tracks app activity and cancels thumbnail URLSession work on resign-active. `ImageLoader` also ignores cancellation after network fetch and after ImageIO downsampling.

`ShareMaster/SettingsView.swift` follows the same rule for the native Settings window: it refreshes on open and when ShareMaster becomes active, without a timer.

## What still runs in the background

User-started transfers are intentionally not tied to app focus. If the user starts an upload or download, `S3Service` should keep working until the transfer finishes or fails. The idle optimisation is aimed at passive work only: cloud-config refresh, object listings, folder browsing reloads, and preview thumbnail downloads.

## Why this matters

Before this change, leaving the popover or Settings window around could still keep a five-second Keychain sync poll alive, and object listings or thumbnail downloads could continue after the user clicked away. Even if each unit of work was small, it was enough to make a menu-bar app show up as active in power/data usage. After the change, an unfocused, non-transferring macOS ShareMaster has no deliberate polling loop and no passive S3/thumbnail network work to perform.

## How to verify

Build the macOS app:

```sh
xcodebuild -project ShareMaster.xcodeproj -scheme ShareMaster -configuration Debug -destination 'platform=macOS' build
```

Then run ShareMaster, open the popover, click another app, and watch Activity Monitor's Energy and Network tabs. With no upload/download in progress, ShareMaster should settle rather than continuing periodic network/listing activity. Reopen the popover or activate Settings to trigger fresh sync/list work again.
