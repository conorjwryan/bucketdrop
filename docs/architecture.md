# Architecture

## Targets and source layout

One Xcode project, `ShareMaster.xcodeproj`, with three app targets built from four source folders:

| Folder | Compiled into | Purpose |
|---|---|---|
| `Shared/` | all three targets | Platform-neutral engine: `ConfigStore`, `S3Service`, `RateLimiter`, `NamingTemplate` |
| `ShareMaster/` | macOS app (`com.cjwr.ShareMaster`) | Menu-bar app: status item + popover (`ContentView`), Settings window (`SettingsView`), app/delegate plumbing (`ShareMasterApp`) |
| `ShareMasterIOS/` | iOS app (`com.cjwr.ShareMasterIOS`, iOS 17+) | Destination list → bucket browser navigation, in-app uploads, settings |
| `ShareMasterShareExt/` | share extension (`com.cjwr.ShareMasterIOS.ShareExt`) | Share-sheet upload flow hosted in `ShareViewController` |

The project uses **synchronized folders** (objectVersion 77): a new `.swift` file dropped into one of these folders is automatically part of the owning target — no project-file edit needed. `Shared/` is a synced folder attached to all three targets.

macOS requires 14.0 (Sonoma); iOS/iPadOS requires 17.0.

## Data model: Accounts and Destinations

The two user-facing concepts, both defined in `Shared/ConfigStore.swift`:

- **Account** — reusable credentials: access key ID, secret access key, region (`auto` for R2), and optional custom endpoint for non-AWS providers. Also carries transfer defaults: `uploadCapMBps`, `downloadCapMBps`, `maxConcurrentParts` (all optionals; `nil` means "use the app default").
- **Destination** — where files actually go: an account reference + bucket + optional path prefix + naming template + link options (public URL base or presigned, expiry) + optional per-destination transfer overrides (`nil` means "inherit from the account") + per-destination download location (macOS) + `isHidden` flag (see [iOS doc](ios.md#hidden-destinations-decoy-mode)).

`ConfigStore.s3Config(for:)` flattens a destination into a single `S3Config` value the transfer engine consumes, resolving every setting as `destination ?? account ?? app default`.

## ConfigStore

`ConfigStore` is an `@Observable` **singleton** (`ConfigStore.shared`) holding `[Account]`, `[Destination]`, and app settings. Storage:

- **Non-secret config** — Codable JSON in UserDefaults. On iOS both the app and the share extension read the **App Group** suite `group.com.cjwr.ShareMaster`; macOS uses standard defaults.
- **Secrets** — never in UserDefaults. Keychain items keyed per account (`account_<uuid>_accessKeyId` / `account_<uuid>_secret`, service `com.cjwr.ShareMaster`). Synchronizable items live in the shared access group `HU9TH52NNC.com.cjwr.ShareMaster.sync` so they ride iCloud Keychain across devices (details in [Sync](sync.md)).

Other notable ConfigStore state: `recentScope`, `recentLimit` (default 5), `recentsExpanded`, `pinPopover`, `lastSelectedDestinationID` (macOS popover selection persistence), `revealHidden` (transient, never persisted), and the device-local sync/cellular toggles (`iCloudSyncEnabled`, `allowsCellularUploads`, `suppressCellularWarnings`).

**Critical convention:** any new Codable field on `Account`/`Destination` **must be an optional** decoded with `decodeIfPresent` — otherwise previously stored JSON (local *and* synced from other devices) fails to decode and the user's config disappears. Default-on Bool settings stored in UserDefaults must load via a `defaults.object(forKey:) != nil` guard so an unset key reads as `true`.

Helper APIs worth knowing: `visibleDestinations` / `visibleAccounts` (respect the hidden/reveal state), `duplicateDraft(of:)` (used by the Duplicate actions on both platforms; a duplicated account copies the source's secrets via `secretsSourceID`), `downloadDirectory(for:)` (macOS security-scoped download folders), `reloadFromDefaults()` (share extension re-reads config since the extension process is reused between presentations).

## How an upload flows (all platforms)

1. UI resolves the target `Destination` and asks `ConfigStore.s3Config(for:)` for a flat `S3Config`.
2. `S3Service` uploads the file — whole-file PUT under 32 MiB, multipart above (see [Transfer engine](transfer-engine.md)) — reporting progress through a single `Double` callback.
3. The file key is produced by `NamingTemplate.expand` from the destination's template.
4. The share link is built per the destination's link mode: public URL base + key, or a SigV4-presigned GET with the configured expiry.
5. The link lands on the pasteboard (NSPasteboard/UIPasteboard) and the UI confirms ("File uploaded and link copied to clipboard" — same wording on iOS in-app and share-extension flows).
