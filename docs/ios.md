# iOS app & share extension

Two iOS targets share the `Shared/` engine with the Mac app: the main app (`ShareMasterIOS/`) and a share extension (`ShareMasterShareExt/`). The share sheet is the primary workflow — the app itself is for setup, browsing, and in-app uploads.

## Storage: App Group

On iOS, `ConfigStore` reads/writes the App Group `group.com.cjwr.ShareMaster` for **both** the UserDefaults suite and the keychain access group (`kSecAttrAccessGroup`, items `kSecAttrAccessibleAfterFirstUnlock`) so the extension sees the same config as the app. macOS storage is unchanged. Cross-*device* sync is separate — see [Sync](sync.md).

## Main app structure

- `ShareMasterIOSApp.swift` — entry point; also warms `NetworkMonitor` at launch (see below).
- `DestinationListView` — root list of destinations → navigates to `BucketBrowserView`. The `NavigationStack` here carries the upload status bar and all upload alerts.
- `BucketBrowserView` — see next section.
- `IOSSettingsView` — account/destination editors (with Duplicate), account transfer defaults, per-destination transfer overrides, Sync section, cellular and preview toggles.
- `UploadMenu` — the toolbar "+": Photo Library (PhotosPicker/`Transferable`, copied to a temp file) and Files (`fileImporter`, security-scoped temp copy). Inside a bucket browser it also offers **New Folder** (hidden when the menu has no fixed destination, i.e. on the root list): a name prompt → `S3Service.createFolder` under the currently open prefix → `onUploaded()` refreshes the listing. See [Transfer engine](transfer-engine.md#creating-folders) for the placeholder-object mechanism and the R2 quirk it works around.
- `UploadManager` — see next section.

## Bucket browser: folders, paging, permissions

`BucketBrowserView` shows one "directory" level at a time via `S3Service.listDirectory` (S3 `delimiter=/` CommonPrefixes — see [Transfer engine](transfer-engine.md#listing--folder-navigation)), **10 entries per page**: a spinner row at the bottom auto-loads the next page as it scrolls into view, pull-to-refresh resets to page one, and each page is a single LIST request so unbrowsed pages cost nothing.

Navigation is prefix-based: the view takes an optional `prefix` (nil = the destination's configured path prefix); tapping a folder row pushes another `BucketBrowserView` for that folder, so the back button walks back up. Above the destination root there's an "up" row (bucket name / parent folder) that navigates toward the bucket root — it appears at the destination root and on levels reached *via* the up row (`showsParentLink`), not on folders drilled into, where back already covers it. An empty folder still shows the list (not the empty state) when an up row exists, so you can always navigate out.

Listing failures that are permission problems (`S3Error.isPermissionIssue`) get a dedicated full-screen state — yellow warning triangle, "Permission Denied", guidance to check the account's credentials and `s3:ListBucket` policy plus the actual S3 message — instead of the generic "Couldn't Load" view. This matters for up-navigation: credentials scoped to the destination's prefix will AccessDenied at the bucket root.

The toolbar "+" uploads **into the folder currently open**: the browser passes its listing prefix through `UploadMenu` → `UploadManager` → `S3Service.upload(keyPrefix:)`, and the status bar names the actual target (destination name when it matches the configured prefix, `bucket/folder` otherwise). Object actions (copy link, preview, delete) work on full keys, so they work on files found outside the destination's prefix too.

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
