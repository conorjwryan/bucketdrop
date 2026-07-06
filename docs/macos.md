# macOS app

The macOS target is a menu-bar-only app (`LSUIElement`, no Dock icon). `ShareMaster/ShareMasterApp.swift` owns the `NSStatusItem` + `NSPopover`; `ContentView.swift` is the popover content; `SettingsView.swift` is the native Settings scene.

## Popover

Layout: destinations sidebar (left) + drop zone / detail (right) + a collapsible **files section**. 560 pt wide; height 212 collapsed / 460 expanded, driven by `NSHostingController.sizingOptions = [.preferredContentSize]`. Content is pinned top so toggling the section never shifts the header/drop zone.

**The files section has two modes**, switched by the folder/clock menu in its header (`ConfigStore.browserPaneMode`, remembered across opens):

- **Browse** (default) — a folder browser for the selected destination, backed by `S3Service.listDirectory`. Folder rows drill in; a `←` back button and a tappable breadcrumb bar climb back up — **all the way to the bucket root**, i.e. above the destination's own `pathPrefix`, since the account's credentials cover the whole bucket. The current folder is remembered per destination across popover teardowns (`ConfigStore.browseLocation(for:)`, macOS-only, not synced). A header sort menu (`BrowserSort`) overrides the destination's default for the session; the default itself lives on `Destination.browserSort` and **is shared with iOS**. Listing failures render inline with permission-aware guidance (`S3Error.isPermissionIssue` → "grant s3:ListBucket") plus Retry / Go Up.
- **Recent (All)** — the flat, newest-first list merged across every visible destination (each row badged with its destination), capped at `recentLimit`. This is the cross-destination glance macOS keeps that iOS doesn't have.

**Lazy lifecycle (important for memory):** the popover content view controller is built on first open and **torn down 60 s after close** (`schedulePopoverTeardown` in ShareMasterApp). Idle footprint ~15 MB, ~50–60 MB after use. Consequences:

- Selection must persist across teardowns — it does, via `ConfigStore.lastSelectedDestinationID`; the browse folder persists via `ConfigStore.browseLocation`.
- Each open re-runs the content `.task`, which is also what picks up synced config changes (see [Sync](sync.md)).
- The section loads **only while expanded**. Its initial state on a fresh install is seeded from the macOS-only `browserDefaultExpanded` preference, then `recentsExpanded` remembers the last state. Thumbnails are 96 px ImageIO downsamples (`ImageLoader`, cache capped at 300). Never decode full-size images for list thumbnails — that's how the app once hit ~190 MB.

**Pin setting:** `ConfigStore.pinPopover` (General settings) switches popover behaviour between `.transient` (default, closes on outside click) and `.semitransient` (stays up). Applied on every `showPopover()`.

## Drag and drop

Two drop surfaces:

1. **Into the open popover** — the drop zone, or directly onto a sidebar destination row. The drop zone and file picker **upload in place**: in Browse mode files land in the folder currently open (`keyPrefix = browsePrefix`), not the destination root; in Recent (All) they go to the destination's configured root. Dropping onto a **sidebar row** always targets that destination's root (a "send to this destination" gesture) and selects it. Rows highlight with an accent pill while hovered (drawn via a negative-padded background because List selection can't be triggered programmatically) and the list auto-scrolls to neighbours during a drag.
2. **Onto the menu bar icon itself** — `StatusItemDragView`, a transparent NSView over the status-item button registered for `.fileURL` drags. Drag-enter opens the popover mid-drag; dropping on the icon posts `.statusItemDidReceiveDrop`, which ContentView uploads to the selected destination's currently-open folder (`uploadKeyPrefix`). It forwards `mouseDown` so click-to-toggle still works.

Uploads thread a `keyPrefix` through `handleDrop` / `openFilePicker` / `uploadFiles` into `S3Service.upload`, which prepends it to the (naming-template-expanded) basename.

After a drag-initiated upload, the popover auto-closes **only if** it was opened by the drag and all uploads succeeded (`popoverOpenedByDrag` + `.uploadDidFinish` in the AppDelegate) — failures keep it open so errors stay visible.

## Settings

Opened via SwiftUI's native `Settings` scene using `@Environment(\.openSettings)` from the popover's gear button (**do not** recreate a custom settings NSWindow — one existed and was removed). Tab order: **General / Accounts / Destinations / Sync / About**. Accounts and Destinations support Duplicate (a duplicated account copies the source's keychain secrets). Hidden destinations and the accounts used only by them are concealed here too until revealed (see [iOS doc](ios.md#hidden-destinations-decoy-mode) — the reveal gesture is tapping the ShareMaster word mark).

**General** carries two macOS-only, non-synced presentation prefs: *Files section starts* Collapsed/Expanded (`browserDefaultExpanded`, seeds first launch) and *Recent (All) shows at most* N (`recentLimit`). **Destination editor** has a *Sort files by* picker writing `Destination.browserSort` — the browse default, shared with iOS.

## Browsing, actions & download locations

Files support Quick Look preview (double-click), copy link, download, and delete; folder rows drill in. The Browse "…" menu adds **New Folder** (`S3Service.createFolder`, a hidden `.folder_placeholder` marker object) and **New Destination Here** — saves a copy of the destination rooted at the current folder via `ConfigStore.upsertDestination` (or **View Destination Settings** when one already exists at that prefix).

Downloads use the engine's concurrent ranged download and honour a **per-destination download location**: `Destination.downloadLocation` (`.downloads` / `.custom` / `.ask`, `nil` = Downloads) with a security-scoped `downloadDirBookmark` for custom folders, resolved by `ConfigStore.downloadDirectory(for:)`. **⌥-click the download button always opens a save panel** regardless of the setting. Entitlements include `files.downloads.read-write` and `files.bookmarks.app-scope`. Unlike iOS there is **no download-state tracking** on macOS — a download is just a real file the user owns in Finder (see the parity plan for the rationale).
