# iOS app & share extension

Two iOS targets share the `Shared/` engine with the Mac app: the main app (`ShareMasterIOS/`) and a share extension (`ShareMasterShareExt/`). The share sheet is the primary workflow — the app itself is for setup, browsing, and in-app uploads.

## Storage: App Group

On iOS, `ConfigStore` reads/writes the App Group `group.com.cjwr.ShareMaster` for **both** the UserDefaults suite and the keychain access group (`kSecAttrAccessGroup`, items `kSecAttrAccessibleAfterFirstUnlock`) so the extension sees the same config as the app. macOS storage is unchanged. Cross-*device* sync is separate — see [Sync](sync.md).

## Main app structure

- `ShareMasterIOSApp.swift` — entry point; also warms `NetworkMonitor` at launch (see below).
- `DestinationListView` — root list of destinations → navigates to `BucketBrowserView`. The `NavigationStack` here carries the upload status bar and all upload alerts.
- `BucketBrowserView` — see next section; its toolbar also carries a "…" menu for creating a destination from the open folder (or jumping to the matching destination's settings).
- `IOSSettingsView` — account/destination editors (with Duplicate), account transfer defaults, per-destination transfer overrides and default browser sort, Sync section, cellular and preview toggles.
- `UploadMenu` — the toolbar "+": Photo Library (PhotosPicker/`Transferable`, copied to a temp file) and Files (`fileImporter`, security-scoped temp copy). Inside a bucket browser it also offers **New Folder** (hidden when the menu has no fixed destination, i.e. on the root list): a name prompt → `S3Service.createFolder` under the currently open prefix → `onUploaded()` refreshes the listing. See [Transfer engine](transfer-engine.md#creating-folders) for the placeholder-object mechanism and the R2 quirk it works around.
- `UploadManager` — see next section.

## Bucket browser: folders, sorting, paging, permissions

`BucketBrowserView` shows one "directory" level at a time via `S3Service.listDirectory` (S3 `delimiter=/` CommonPrefixes — see [Transfer engine](transfer-engine.md#listing--folder-navigation)). How the level loads depends on the sort order:

- **Name (A to Z)** — S3's native listing order, so it pages lazily, **200 entries per page**: a spinner row at the bottom auto-loads the next page as it scrolls into view, and pull-to-refresh resets to page one. Pages were originally 10 keys on a cost assumption that turned out wrong — both AWS and R2 bill LIST **per request, not per key** ([Provider policies](provider_policies.md)), so a 200-key page costs the same as a 10-key one and small pages just multiply requests. Paging is kept only so enormous folders load incrementally.
- **Recently Uploaded** (the default) and **Name (Z to A)** — the S3 API can't page these orders (no provider offers server-side date or reverse ordering), so the browser fetches the **whole level up front** (same 200-key pages, capped at 25 requests ≈ 5,000 entries as a runaway guard) and sorts client-side (`BucketBrowserView.sorted`). No spinner row — everything is already loaded. Folders have no upload date, so under Recently Uploaded they keep name order; files sort by `lastModified` descending.

The order comes from `BrowserSort` (`Shared/ConfigStore.swift`): each destination stores a default (`Destination.browserSort`, optional in the JSON so old configs decode; the `defaultBrowserSort` accessor falls back to `.recentFirst`), set in `DestinationEditorView`'s **Browsing** section. The "…" menu's **Sort By** picker overrides it for the current view only (`sortOverride`, per pushed browser instance, not persisted). The browser reads the destination's default live from `ConfigStore`, so changing it in the settings sheet opened from the "…" menu reloads the listing on dismiss when the effective order changed.

Navigation is prefix-based: the view takes an optional `prefix` (nil = the destination's configured path prefix); tapping a folder row pushes another `BucketBrowserView` for that folder, so the back button walks back up. Above the destination root there's an "up" row (bucket name / parent folder) that navigates toward the bucket root — it appears at the destination root and on levels reached *via* the up row (`showsParentLink`), not on folders drilled into, where back already covers it. An empty folder still shows the list (not the empty state) when an up row exists, so you can always navigate out.

Listing failures that are permission problems (`S3Error.isPermissionIssue`) get a dedicated full-screen state — yellow warning triangle, "Permission Denied", guidance to check the account's credentials and `s3:ListBucket` policy plus the actual S3 message — instead of the generic "Couldn't Load" view. This matters for up-navigation: credentials scoped to the destination's prefix will AccessDenied at the bucket root.

The toolbar "+" uploads **into the folder currently open**: the browser passes its listing prefix through `UploadMenu` → `UploadManager` → `S3Service.upload(keyPrefix:)`, and the status bar names the actual target (destination name when it matches the configured prefix, `bucket/folder` otherwise). Object actions (copy link, preview, delete) work on full keys, so they work on files found outside the destination's prefix too.

### The "…" menu: sorting and destinations from folders

Next to the "+" there's a context-aware "…" menu, present at every browser level (including levels above the destination root reached via the up row):

- **Sort By** — Recently Uploaded / Name (A to Z) / Name (Z to A), a per-visit override of the destination's default order (see the sorting section above). Changing it re-fetches the level immediately.
- **New Destination Here** — saves a copy of the destination being browsed with a fresh ID, a prompted name, and `pathPrefix` set to the open folder. Everything else (account, bucket, link mode, naming template, transfer overrides, the `hidden` flag, the default browser sort) is inherited, so no credentials are re-entered and the copy syncs across devices like any other edit (see [Sync](sync.md)). The name prompt pre-fills with the folder's name, suffixed via `ConfigStore.copyName` only when that name is already taken. `upsertDestination` normalizes the prefix and appends the copy to the end of the list.
- **View Destination Settings** — shown *instead* when the open folder is already the root of an existing destination (same account + bucket + normalized prefix, matched across **all** destinations, not just the one being browsed). Opens the standard `DestinationEditorView` sheet, so you can't create an accidental duplicate of a destination that already exists.

## In-app uploads: UploadManager

`UploadManager` (`@MainActor @Observable` singleton) makes uploads **non-blocking**: it queues batches, runs them sequentially, copies the resulting link(s) to UIPasteboard when the destination setting allows it, and holds a `beginBackgroundTask` so a transfer survives ~30 s after backgrounding. It is **not** a background `URLSession` — very large files still suspend with the app; a full background-session rework of `S3Service` was scoped and deliberately deferred.

`UploadStatusBar` (same file) is a floating bottom bar attached via `.safeAreaInset(edge: .bottom)`: progress while uploading → green completion message, with clipboard wording only when the destination's copy-on-upload setting is enabled (auto-clears after 4 s) → failures persist with an ✕. Uploads started from inside a bucket browser go straight to that destination, into the folder currently open (see the bucket browser section); uploads from the root list first show a `UploadDestinationPicker` sheet and use the destination's configured prefix.

**Presentation rule (bug happened twice):** the status bar and every upload alert must hang off the **NavigationStack itself**, not the root list view — presentations from a covered root don't reliably appear while a bucket view is pushed.

## Mobile-data gating

iOS-app-only, uploads-only for transfer blocking (browsing and link-copying are never gated; the app has no file-download feature yet). Controlled by the device-local settings `allowsCellularUploads` (default on) and `suppressCellularWarnings` (default off). Image previews have their own device-local controls: `rendersFullImagePreviews` (default off, decode a bounded display copy) and `requiresTapForCellularPreviews` (default on, show a Preview button before fetching image bytes on mobile data).

- `NetworkMonitor` (an `@Observable` `NWPathMonitor` wrapper in `UploadManager.swift`) **must be warmed at launch** — it's touched in `UploadManager.init` because the first path reading is asynchronous, so a lazily created monitor always reports "not cellular".
- On cellular, `UploadManager.start` either shows an "Uploading on Mobile Data Is Disabled" alert (toggle off) or a "~X MB of your mobile data plan" Continue/Cancel prompt (toggle on, warnings not suppressed).
- Enforcement backstop: `S3Config.allowsCellular` → `allowsCellularAccess` on the upload requests; a resulting `URLError` (`.dataNotAllowed` etc.) while gated is mapped to the friendly disabled alert in `UploadManager.run()`.
- The share extension has **no gate UI** — when uploads are disallowed on cellular it simply fails at the network level.
- On cellular, `RemoteImagePreview` waits for an explicit tap before it downloads the image unless `requiresTapForCellularPreviews` is off. Wi-Fi previews still load automatically. The full-size preview toggle only changes decode size, not object download size.

## Hidden destinations ("decoy mode")

`Destination.isHidden` hides a destination **everywhere** — the iOS list, the share sheet, the Mac popover, and both platforms' Settings — along with any account used *only* by hidden destinations. The transient reveal switch is `ConfigStore.revealHidden`, toggled by **tapping the ShareMaster word mark** (iOS root list or Mac popover); it re-conceals when the iOS app leaves the foreground and on each Mac popover open.

Decoy behaviour is deliberate: if *all* destinations are hidden, the root list shows the fresh-install empty state and the "+" upload menu is disabled (`visibleDestinations.isEmpty`), so the app is indistinguishable from an unconfigured install.

## Share extension

`ShareViewController` (principal class) hosts `ShareUploadView`: tap a destination → upload with progress → link on UIPasteboard → auto-dismiss (errors cancel the request instead). Because iOS reuses the extension process between share-sheet presentations, `viewDidLoad` calls `ConfigStore.shared.reloadFromDefaults()` to pick up config edited in the main app since the last invocation. Uses the same confirmation wording as the in-app flow.
