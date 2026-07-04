# iOS app & share extension

Two iOS targets share the `Shared/` engine with the Mac app: the main app (`ShareMasterIOS/`) and a share extension (`ShareMasterShareExt/`). The share sheet is the primary workflow — the app itself is for setup, browsing, and in-app uploads.

## Storage: App Group

On iOS, `ConfigStore` reads/writes the App Group `group.com.cjwr.ShareMaster` for **both** the UserDefaults suite and the keychain access group (`kSecAttrAccessGroup`, items `kSecAttrAccessibleAfterFirstUnlock`) so the extension sees the same config as the app. macOS storage is unchanged. Cross-*device* sync is separate — see [Sync](sync.md).

## Main app structure

- `ShareMasterIOSApp.swift` — entry point; also warms `NetworkMonitor` at launch (see below).
- `DestinationListView` — root list of destinations → navigates to `BucketBrowserView` (browse objects, copy links, delete). The `NavigationStack` here carries the upload status bar and all upload alerts.
- `IOSSettingsView` — account/destination editors (with Duplicate), Sync section, cellular toggles.
- `UploadMenu` — the toolbar "+": Photo Library (PhotosPicker/`Transferable`, copied to a temp file) and Files (`fileImporter`, security-scoped temp copy).
- `UploadManager` — see next section.

## In-app uploads: UploadManager

`UploadManager` (`@MainActor @Observable` singleton) makes uploads **non-blocking**: it queues batches, runs them sequentially, copies the resulting link(s) to UIPasteboard, and holds a `beginBackgroundTask` so a transfer survives ~30 s after backgrounding. It is **not** a background `URLSession` — very large files still suspend with the app; a full background-session rework of `S3Service` was scoped and deliberately deferred.

`UploadStatusBar` (same file) is a floating bottom bar attached via `.safeAreaInset(edge: .bottom)`: progress while uploading → green "File uploaded and link copied to clipboard" (auto-clears after 4 s) → failures persist with an ✕. Uploads started from inside a bucket browser go straight to that destination; uploads from the root list first show a `UploadDestinationPicker` sheet.

**Presentation rule (bug happened twice):** the status bar and every upload alert must hang off the **NavigationStack itself**, not the root list view — presentations from a covered root don't reliably appear while a bucket view is pushed.

## Mobile-data gating

iOS-app-only, uploads-only (browsing and link-copying are never gated; the app has no file-download feature yet). Controlled by the device-local settings `allowsCellularUploads` (default on) and `suppressCellularWarnings` (default off).

- `NetworkMonitor` (an `@Observable` `NWPathMonitor` wrapper in `UploadManager.swift`) **must be warmed at launch** — it's touched in `UploadManager.init` because the first path reading is asynchronous, so a lazily created monitor always reports "not cellular".
- On cellular, `UploadManager.start` either shows an "Uploading on Mobile Data Is Disabled" alert (toggle off) or a "~X MB of your mobile data plan" Continue/Cancel prompt (toggle on, warnings not suppressed).
- Enforcement backstop: `S3Config.allowsCellular` → `allowsCellularAccess` on the upload requests; a resulting `URLError` (`.dataNotAllowed` etc.) while gated is mapped to the friendly disabled alert in `UploadManager.run()`.
- The share extension has **no gate UI** — when uploads are disallowed on cellular it simply fails at the network level.

## Hidden destinations ("decoy mode")

`Destination.isHidden` hides a destination **everywhere** — the iOS list, the share sheet, the Mac popover, and both platforms' Settings — along with any account used *only* by hidden destinations. The transient reveal switch is `ConfigStore.revealHidden`, toggled by **tapping the ShareMaster word mark** (iOS root list or Mac popover); it re-conceals when the iOS app leaves the foreground and on each Mac popover open.

Decoy behaviour is deliberate: if *all* destinations are hidden, the root list shows the fresh-install empty state and the "+" upload menu is disabled (`visibleDestinations.isEmpty`), so the app is indistinguishable from an unconfigured install.

## Share extension

`ShareViewController` (principal class) hosts `ShareUploadView`: tap a destination → upload with progress → link on UIPasteboard → auto-dismiss (errors cancel the request instead). Because iOS reuses the extension process between share-sheet presentations, `viewDidLoad` calls `ConfigStore.shared.reloadFromDefaults()` to pick up config edited in the main app since the last invocation. Uses the same confirmation wording as the in-app flow.
