# macOS app

The macOS target is a menu-bar-only app (`LSUIElement`, no Dock icon). `ShareMaster/ShareMasterApp.swift` owns the `NSStatusItem` + `NSPopover`; `ContentView.swift` is the popover content; `SettingsView.swift` is the native Settings scene.

## Menu bar item

The status-item glyph is a **template image** (`isTemplate`, so the system tints it white/black to match the bar). Four styles ship as template imagesets — `MenuBarPlaneFill` / `MenuBarBoxFill` / `MenuBarPlaneOutline` / `MenuBarBoxOutline` — chosen by `ConfigStore.menuBarIconStyle` (`MenuBarIconStyle` enum, macOS-only pref `config_menu_bar_icon_style`, **not synced**; default `.planeFill`). The **General** settings dropdown writes it; changing it posts `.menuBarIconStyleChanged`, which `applyMenuBarIcon()` observes to swap the image live (no relaunch).

Those PNGs are **generated from the colour logo art** (`LogoBox` / `LogoPlane`): a Swift/CoreGraphics script extracts the dark navy outline (→ *outline* style) or flood-fills the enclosed region with the outline carved back out as negative space (→ *solid* style, like a filled SF Symbol), dilates so the stroke survives the downscale, then **trims the transparent margin** so the glyph fills the frame rather than floating in padding (that padding was why it first looked small). Rendered at 48 px, displayed at 20 pt.

**Selection highlight:** `button.highlight(true)` on open shows the standard rounded selection pill. It's **deferred one runloop tick** — the click arrives via `StatusItemDragView.performClick(_:)`, which highlights then un-highlights as it returns, so a synchronous call gets wiped. Cleared on `NSPopover.willCloseNotification` (not `didClose`, which fires only after the close animation and leaves the pill lingering).

**Right-click / control-click menu** (Settings…, Quit): presented by assigning `statusItem.menu` and calling `performClick`, then detaching it in `menuDidClose` so left-click still opens the popover. Do **not** use `NSMenu.popUp(in: button)` — a menu anchored to the status button inherits the menu bar's dark/vibrant appearance and renders dark even in Light Mode; the system-presented `statusItem.menu` uses the correct appearance and draws its own highlight.

**Appearance gotcha:** anything anchored to the status button inherits the menu bar's appearance. `showPopover()` sets `popover.appearance = NSApp.effectiveAppearance` so the popover follows the system Light/Dark setting instead of rendering dark in Light Mode.

## Popover

A Finder-like file browser laid out top-to-bottom: **header** (brand logo + word mark, then the New Folder / Refresh / Settings / Quit icon buttons) → **full-width breadcrumb bar** → **body** (destinations sidebar on the left, file table on the right) → **drop zone** pinned at the bottom. Fixed **780 × 580 pt**, driven by `NSHostingController.sizingOptions = [.preferredContentSize]`.

The brand logo (`ShareMasterLogo`) renders the `LogoPlane` asset beside the word mark. Tapping the **word mark** is still the hidden reveal gesture for hidden destinations.

**The file table always shows** (there's no longer a collapse-to-small state — `recentsExpanded` is forced `true` on open, so the old `browserDefaultExpanded` seed is vestigial on macOS). Columns are **Name / Date / Size**; the Name and Date headers are clickable to sort. A **`≡` options menu** at the right of the column header holds the sort options, the view-mode switch, and the Browse folder/destination actions. It has two modes (`ConfigStore.browserPaneMode`, remembered across opens):

- **Browse** (default) — a folder browser for the selected destination, backed by `S3Service.listDirectory`. Folder rows drill in; a `‹` back button in the column header and the **persistent breadcrumb bar** (with a home button = bucket root) climb back up — **all the way to the bucket root**, i.e. above the destination's own `pathPrefix`, since the account's credentials cover the whole bucket. A row single-click selects it (blue highlight + inline Copy Link / Download / Preview / Delete actions on an opaque backing so they don't bleed over the columns); double-click Quick Looks. Sort (`BrowserSort`) overrides the destination's default for the session; the default itself lives on `Destination.browserSort` and **is shared with iOS**. Listing failures render inline with permission-aware guidance (`S3Error.isPermissionIssue` → "grant s3:ListBucket") plus Retry / Go Up.
- **Recent (All)** — the flat, newest-first list merged across every visible destination (each row badged with its destination), capped at `recentLimit`. This is the cross-destination glance macOS keeps that iOS doesn't have.

**Destination navigation state:** the last-viewed folder of the focused destination is restored on popover open (`ConfigStore.browseLocation(for:)`, macOS-only, not synced), so reopening returns you where you were. But **tapping a destination in the sidebar always resets it to its configured root** — even tapping the already-selected one — via `selectDestination(_:)`; navigation you do afterwards persists until the next such tap. (This is deliberate: destination taps go "home"; a drop onto a sidebar row does the same before uploading.)

**Sidebar:** a "DESTINATIONS" list of custom rows (not a `List` — a `LazyVStack` with tap selection, so selection/drop highlighting is drawn directly rather than fighting `List`). Each row shows a per-destination icon — an SF Symbol + colour chosen in Settings (`Destination.iconSymbol` / `iconTint`), defaulting to a folder tinted stably from the id (`DestinationIcon` / `destinationIconStyle`). The footer has **`+`** (add destination → opens Settings' editor) on the left and **`«`** (collapse) on the right. Collapsing swaps the sidebar for a thin 46 pt **rail** that keeps `+` and **`»`** (expand) pinned to the bottom in the same spot, and the file table shifts to fill the freed width.

**Lazy lifecycle (important for memory):** the popover content view controller is built on first open and **torn down 60 s after close** (`schedulePopoverTeardown` in ShareMasterApp). Idle footprint ~15 MB, ~50–60 MB after use. Consequences:

- Selection must persist across teardowns — it does, via `ConfigStore.lastSelectedDestinationID`; the browse folder persists via `ConfigStore.browseLocation` (restored on open only — see the destination-navigation note above).
- Opening the menu-bar popover calls `ConfigStore.refreshFromCloud()` in `showPopover()`, so it picks up synced config changes even when the cached SwiftUI content is reused during the 60 s teardown delay (see [Sync](sync.md)).
- Thumbnails are 96 px ImageIO downsamples (`ImageLoader`, cache capped at 300). Never decode full-size images for list thumbnails — that's how the app once hit ~190 MB.

**Idle / App Nap behaviour (important for battery):** the app relies on macOS App Nap, but it also has to avoid keeping itself awake. There is no periodic iCloud Keychain sync poll. `showPopover()` pulls cloud config when the menu-bar item opens, `ContentView`/`SettingsView` refresh when ShareMaster becomes active, Browse and Recent (All) reloads are routed through cancellable foreground list tasks, stale listing completions do not update the UI after focus is lost, and thumbnail URLSession work is cancelled on resign-active. Explicit uploads/downloads still continue while unfocused; only passive sync/list/preview work goes quiet. See [Battery optimisations](battery-optimisations.md) for the focused note.

**Pin setting:** `ConfigStore.pinPopover` (General settings) switches popover behaviour between `.transient` (default, closes on outside click) and `.semitransient` (stays up). Applied on every `showPopover()`.

## Drag and drop

Two drop surfaces:

1. **Into the open popover** — the drop zone, or directly onto a sidebar destination row. The drop zone and file picker **upload in place**: in Browse mode files land in the folder currently open (`keyPrefix = browsePrefix`), not the destination root; in Recent (All) they go to the destination's configured root. Dropping onto a **sidebar row** routes through `selectDestination(_:)` — it selects that destination and resets it to its root (a "send to this destination" gesture) before uploading. Rows highlight with an accent fill while a drag hovers, and the list auto-scrolls to neighbours during a drag.
2. **Onto the menu bar icon itself** — `StatusItemDragView`, a transparent NSView over the status-item button registered for `.fileURL` drags. Drag-enter opens the popover mid-drag; dropping on the icon posts `.statusItemDidReceiveDrop`, which ContentView uploads to the selected destination's currently-open folder (`uploadKeyPrefix`). It forwards `mouseDown` so click-to-toggle still works, and `rightMouseDown` (plus control-click) opens the status menu (see [Menu bar item](#menu-bar-item)).

Uploads thread a `keyPrefix` through `handleDrop` / `openFilePicker` / `uploadFiles` into `S3Service.upload`, which prepends it to the (naming-template-expanded) basename.

After a drag-initiated upload, the popover auto-closes **only if** it was opened by the drag and all uploads succeeded (`popoverOpenedByDrag` + `.uploadDidFinish` in the AppDelegate) — failures keep it open so errors stay visible.

## Settings

Opened via SwiftUI's native `Settings` scene using `@Environment(\.openSettings)` from the popover's gear button (**do not** recreate a custom settings NSWindow — one existed and was removed). It's also reachable from the menu-bar item's right-click menu, which opens it via the `showSettingsWindow:` AppKit action. Tab order: **General / Accounts / Destinations / Sync / About**. Accounts and Destinations support Duplicate (a duplicated account copies the source's keychain secrets). Hidden destinations and the accounts used only by them are concealed here too until revealed (see [iOS doc](ios.md#hidden-destinations-decoy-mode) — the reveal gesture is tapping the ShareMaster word mark).

**Deleting** an account, destination, or file is guarded by an "are you sure?" confirmation (`confirmationDialog`) — accounts warn that Keychain credentials go too; destinations note the bucket's files are untouched; files warn the delete is permanent. (Accounts still also refuse to delete while a destination references them.)

**General** carries the macOS-only, non-synced *Recent (All) shows at most* N pref (`recentLimit`) and the **Menu bar icon** dropdown (`menuBarIconStyle` — see [Menu bar item](#menu-bar-item)). (`browserDefaultExpanded` still exists but is inert now the table is always shown.) **Destination editor** has a *Sort files by* picker writing `Destination.browserSort` (the browse default, shared with iOS) and an **Icon** section — a colour-swatch row + SF Symbol grid writing `Destination.iconSymbol` / `iconTint`. Those fields decode on iOS but the picker and sidebar icons are **macOS-only for now** (see the memory note / future iOS parity task).

## Browsing, actions & download locations

Files support Quick Look preview (double-click), copy link, download, and delete (inline actions on the selected/hovered row); folder rows drill in. **New Folder** is a header button (`S3Service.createFolder`, a hidden `.folder_placeholder` marker object); it's also in the column-header `≡` menu, which additionally offers **New Destination Here** — saves a copy of the destination rooted at the current folder via `ConfigStore.upsertDestination` (or **View Destination Settings** when one already exists at that prefix).

Downloads use the engine's concurrent ranged download and honour a **per-destination download location**: `Destination.downloadLocation` (`.downloads` / `.custom` / `.ask`, `nil` = Downloads) with a security-scoped `downloadDirBookmark` for custom folders, resolved by `ConfigStore.downloadDirectory(for:)`. **⌥-click the download button always opens a save panel** regardless of the setting. Entitlements include `files.downloads.read-write` and `files.bookmarks.app-scope`. Unlike iOS there is **no download-state tracking** on macOS — a download is just a real file the user owns in Finder (see the parity plan for the rationale).
