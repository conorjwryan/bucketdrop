# macOS app

The macOS target is a menu-bar-only app (`LSUIElement`, no Dock icon). `ShareMaster/ShareMasterApp.swift` owns the `NSStatusItem` + `NSPopover`; `ContentView.swift` is the popover content; `SettingsView.swift` is the native Settings scene.

## Popover

A Finder-like file browser laid out top-to-bottom: **header** (brand logo + word mark, then the New Folder / Refresh / Settings / Quit icon buttons) → **full-width breadcrumb bar** → **body** (destinations sidebar on the left, file table on the right) → **drop zone** pinned at the bottom. Fixed **780 × 580 pt**, driven by `NSHostingController.sizingOptions = [.preferredContentSize]`.

The brand logo (`ShareMasterLogo`) composites two asset-catalog images — `LogoBox` + `LogoPlane`, copied from `Shared/sharemaster.icon/Assets` — into the app-icon mark (a paper plane flying out of an open box). Tapping the **word mark** is still the hidden reveal gesture for hidden destinations.

**The file table always shows** (there's no longer a collapse-to-small state — `recentsExpanded` is forced `true` on open, so the old `browserDefaultExpanded` seed is vestigial on macOS). Columns are **Name / Date / Size**; the Name and Date headers are clickable to sort. A **`≡` options menu** at the right of the column header holds the sort options, the view-mode switch, and the Browse folder/destination actions. It has two modes (`ConfigStore.browserPaneMode`, remembered across opens):

- **Browse** (default) — a folder browser for the selected destination, backed by `S3Service.listDirectory`. Folder rows drill in; a `‹` back button in the column header and the **persistent breadcrumb bar** (with a home button = bucket root) climb back up — **all the way to the bucket root**, i.e. above the destination's own `pathPrefix`, since the account's credentials cover the whole bucket. A row single-click selects it (blue highlight + inline Copy Link / Download / Preview / Delete actions on an opaque backing so they don't bleed over the columns); double-click Quick Looks. Sort (`BrowserSort`) overrides the destination's default for the session; the default itself lives on `Destination.browserSort` and **is shared with iOS**. Listing failures render inline with permission-aware guidance (`S3Error.isPermissionIssue` → "grant s3:ListBucket") plus Retry / Go Up.
- **Recent (All)** — the flat, newest-first list merged across every visible destination (each row badged with its destination), capped at `recentLimit`. This is the cross-destination glance macOS keeps that iOS doesn't have.

**Destination navigation state:** the last-viewed folder of the focused destination is restored on popover open (`ConfigStore.browseLocation(for:)`, macOS-only, not synced), so reopening returns you where you were. But **tapping a destination in the sidebar always resets it to its configured root** — even tapping the already-selected one — via `selectDestination(_:)`; navigation you do afterwards persists until the next such tap. (This is deliberate: destination taps go "home"; a drop onto a sidebar row does the same before uploading.)

**Sidebar:** a "DESTINATIONS" list of custom rows (not a `List` — a `LazyVStack` with tap selection, so selection/drop highlighting is drawn directly rather than fighting `List`). Each row shows a per-destination icon — an SF Symbol + colour chosen in Settings (`Destination.iconSymbol` / `iconTint`), defaulting to a folder tinted stably from the id (`DestinationIcon` / `destinationIconStyle`). The footer has **`+`** (add destination → opens Settings' editor) on the left and **`«`** (collapse) on the right. Collapsing swaps the sidebar for a thin 46 pt **rail** that keeps `+` and **`»`** (expand) pinned to the bottom in the same spot, and the file table shifts to fill the freed width.

**Lazy lifecycle (important for memory):** the popover content view controller is built on first open and **torn down 60 s after close** (`schedulePopoverTeardown` in ShareMasterApp). Idle footprint ~15 MB, ~50–60 MB after use. Consequences:

- Selection must persist across teardowns — it does, via `ConfigStore.lastSelectedDestinationID`; the browse folder persists via `ConfigStore.browseLocation` (restored on open only — see the destination-navigation note above).
- Each open re-runs the content `.task`, which is also what picks up synced config changes (see [Sync](sync.md)).
- Thumbnails are 96 px ImageIO downsamples (`ImageLoader`, cache capped at 300). Never decode full-size images for list thumbnails — that's how the app once hit ~190 MB.

**Pin setting:** `ConfigStore.pinPopover` (General settings) switches popover behaviour between `.transient` (default, closes on outside click) and `.semitransient` (stays up). Applied on every `showPopover()`.

## Drag and drop

Two drop surfaces:

1. **Into the open popover** — the drop zone, or directly onto a sidebar destination row. The drop zone and file picker **upload in place**: in Browse mode files land in the folder currently open (`keyPrefix = browsePrefix`), not the destination root; in Recent (All) they go to the destination's configured root. Dropping onto a **sidebar row** routes through `selectDestination(_:)` — it selects that destination and resets it to its root (a "send to this destination" gesture) before uploading. Rows highlight with an accent fill while a drag hovers, and the list auto-scrolls to neighbours during a drag.
2. **Onto the menu bar icon itself** — `StatusItemDragView`, a transparent NSView over the status-item button registered for `.fileURL` drags. Drag-enter opens the popover mid-drag; dropping on the icon posts `.statusItemDidReceiveDrop`, which ContentView uploads to the selected destination's currently-open folder (`uploadKeyPrefix`). It forwards `mouseDown` so click-to-toggle still works.

Uploads thread a `keyPrefix` through `handleDrop` / `openFilePicker` / `uploadFiles` into `S3Service.upload`, which prepends it to the (naming-template-expanded) basename.

After a drag-initiated upload, the popover auto-closes **only if** it was opened by the drag and all uploads succeeded (`popoverOpenedByDrag` + `.uploadDidFinish` in the AppDelegate) — failures keep it open so errors stay visible.

## Settings

Opened via SwiftUI's native `Settings` scene using `@Environment(\.openSettings)` from the popover's gear button (**do not** recreate a custom settings NSWindow — one existed and was removed). Tab order: **General / Accounts / Destinations / Sync / About**. Accounts and Destinations support Duplicate (a duplicated account copies the source's keychain secrets). Hidden destinations and the accounts used only by them are concealed here too until revealed (see [iOS doc](ios.md#hidden-destinations-decoy-mode) — the reveal gesture is tapping the ShareMaster word mark).

**General** carries the macOS-only, non-synced *Recent (All) shows at most* N pref (`recentLimit`). (`browserDefaultExpanded` still exists but is inert now the table is always shown.) **Destination editor** has a *Sort files by* picker writing `Destination.browserSort` (the browse default, shared with iOS) and an **Icon** section — a colour-swatch row + SF Symbol grid writing `Destination.iconSymbol` / `iconTint`. Those fields decode on iOS but the picker and sidebar icons are **macOS-only for now** (see the memory note / future iOS parity task).

## Browsing, actions & download locations

Files support Quick Look preview (double-click), copy link, download, and delete (inline actions on the selected/hovered row); folder rows drill in. **New Folder** is a header button (`S3Service.createFolder`, a hidden `.folder_placeholder` marker object); it's also in the column-header `≡` menu, which additionally offers **New Destination Here** — saves a copy of the destination rooted at the current folder via `ConfigStore.upsertDestination` (or **View Destination Settings** when one already exists at that prefix).

Downloads use the engine's concurrent ranged download and honour a **per-destination download location**: `Destination.downloadLocation` (`.downloads` / `.custom` / `.ask`, `nil` = Downloads) with a security-scoped `downloadDirBookmark` for custom folders, resolved by `ConfigStore.downloadDirectory(for:)`. **⌥-click the download button always opens a save panel** regardless of the setting. Entitlements include `files.downloads.read-write` and `files.bookmarks.app-scope`. Unlike iOS there is **no download-state tracking** on macOS — a download is just a real file the user owns in Finder (see the parity plan for the rationale).
