# macOS app

The macOS target is a menu-bar-only app (`LSUIElement`, no Dock icon). `ShareMaster/ShareMasterApp.swift` owns the `NSStatusItem` + `NSPopover`; `ContentView.swift` is the popover content; `SettingsView.swift` is the native Settings scene.

## Popover

Layout: destinations sidebar (left) + drop zone / detail (right) + a collapsible **Recent Uploads** section. 560 pt wide; height 212 collapsed / 460 with recents expanded, driven by `NSHostingController.sizingOptions = [.preferredContentSize]`. Content is pinned top so toggling recents never shifts the header/drop zone.

**Lazy lifecycle (important for memory):** the popover content view controller is built on first open and **torn down 60 s after close** (`schedulePopoverTeardown` in ShareMasterApp). Idle footprint ~15 MB, ~50–60 MB after use. Consequences:

- Selection must persist across teardowns — it does, via `ConfigStore.lastSelectedDestinationID`.
- Each open re-runs the content `.task`, which is also what picks up synced config changes (see [Sync](sync.md)).
- Recents load **only while expanded**, capped at `recentLimit`; thumbnails are 96 px ImageIO downsamples (`ImageLoader`, cache capped at 300). Never decode full-size images for list thumbnails — that's how the app once hit ~190 MB.

**Pin setting:** `ConfigStore.pinPopover` (General settings) switches popover behaviour between `.transient` (default, closes on outside click) and `.semitransient` (stays up). Applied on every `showPopover()`.

## Drag and drop

Two drop surfaces:

1. **Into the open popover** — the drop zone, or directly onto a sidebar destination row. Rows highlight with an accent pill while hovered (drawn via a negative-padded background because List selection can't be triggered programmatically) and the list auto-scrolls to neighbours during a drag. Dropping on a row selects that destination.
2. **Onto the menu bar icon itself** — `StatusItemDragView`, a transparent NSView over the status-item button registered for `.fileURL` drags. Drag-enter opens the popover mid-drag; dropping on the icon posts `.statusItemDidReceiveDrop`, which ContentView uploads to the currently selected destination. It forwards `mouseDown` so click-to-toggle still works.

After a drag-initiated upload, the popover auto-closes **only if** it was opened by the drag and all uploads succeeded (`popoverOpenedByDrag` + `.uploadDidFinish` in the AppDelegate) — failures keep it open so errors stay visible.

## Settings

Opened via SwiftUI's native `Settings` scene using `@Environment(\.openSettings)` from the popover's gear button (**do not** recreate a custom settings NSWindow — one existed and was removed). Tab order: **General / Accounts / Destinations / Sync / About**. Accounts and Destinations support Duplicate (a duplicated account copies the source's keychain secrets). Hidden destinations and the accounts used only by them are concealed here too until revealed (see [iOS doc](ios.md#hidden-destinations-decoy-mode) — the reveal gesture is tapping the ShareMaster word mark).

## Recents actions & download locations

Recent uploads support Quick Look preview, copy link, download, and delete. Downloads use the engine's concurrent ranged download and honour a **per-destination download location**: `Destination.downloadLocation` (`.downloads` / `.custom` / `.ask`, `nil` = Downloads) with a security-scoped `downloadDirBookmark` for custom folders, resolved by `ConfigStore.downloadDirectory(for:)`. **⌥-click the download button always opens a save panel** regardless of the setting. Entitlements include `files.downloads.read-write` and `files.bookmarks.app-scope`.
