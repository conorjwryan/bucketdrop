# Cross-device sync

Config (accounts, destinations, settings) and credentials sync between macOS and iOS through **iCloud Keychain only**. There is no CloudKit and no iCloud key-value store: the signing team (`HU9TH52NNC`) is a free personal Apple Developer team, which cannot enable those capabilities. All sync logic lives in `Shared/ConfigStore.swift`.

## Mechanism

- All per-account secrets **and** a whole-config JSON payload (keychain item `cloud_config_payload`) are stored as `kSecAttrSynchronizable` keychain items in the shared access group `HU9TH52NNC.com.cjwr.ShareMaster.sync`. The entitlement `$(AppIdentifierPrefix)com.cjwr.ShareMaster.sync` is present in all three targets; on macOS the queries additionally need `kSecUseDataProtectionKeychain`.
- Account/destination transfer settings are part of that synced config: account upload/download caps and concurrent-part defaults sync, and destination overrides sync with the destination.
- Conflict resolution is **last-writer-wins**: the payload carries an `updatedAt` timestamp compared against the locally stored `config_cloud_updated_at`; `adoptCloudIfNewer()` bails when the versions match.
- Every local mutation calls `pushToCloud()` (guarded by `isAdoptingCloud` so adopting a remote payload doesn't immediately re-push it).

## Refresh triggers (there are no keychain change notifications)

Apple's keychain posts no change events, so every surface refreshes explicitly at user entry points rather than polling:

| Surface | Trigger |
|---|---|
| macOS menu-bar click / popover open | `ShareMasterApp.showPopover()` calls `refreshFromCloud()` every time the menu-bar item opens, including quick reopens while the cached popover content is still alive |
| macOS popover content | `refreshFromCloud()` in the content `.task` when the SwiftUI hierarchy is created, plus another refresh when ShareMaster becomes active |
| macOS Settings window | `refreshFromCloud()` on appear and when ShareMaster becomes active |
| iOS app | `refreshFromCloud()` on root view load and whenever `scenePhase` becomes active |
| Share extension | `ConfigStore` init adopts the cloud payload; `reloadFromDefaults()` on each presentation because the extension process is reused |

## Migration & fallbacks

Legacy keychain items (macOS login keychain from the pre-sync era, iOS app-group items) are read-through-migrated into the sync group on first access. `keychainSet` falls back to legacy storage on `errSecMissingEntitlement` so unsigned/dev builds without the sync entitlement still work.

## Device-local settings (deliberately NOT synced)

`iCloudSyncEnabled` (default on), `allowsCellularUploads` (default on; gates both uploads and downloads despite the name — labelled "Transfer on Mobile Data"), `suppressCellularWarnings` (default off), the preview toggles (`rendersFullImagePreviews`, `requiresTapForCellularPreviews`), and `showsDownloadsInFilesApp` (default on) are per-device UserDefaults and excluded from the synced payload — turning sync off on one device must not propagate, and cellular/storage preferences are inherently per-device. `iCloudSyncEnabled` gates `startCloudSync`/`pushToCloud`/`adoptCloudIfNewer`; re-enabling it adopts the cloud payload first, then pushes.

Downloaded files themselves ([iOS downloads](ios.md#downloads--offline-files)) are also strictly per-device: the manifest and local copies never sync — each device downloads its own.

Settings UI: iOS has a Sync section in `IOSSettingsView` (three toggles; "suppress warnings" is disabled unless mobile-data transfers are allowed) plus Previews and Downloads sections; macOS has a Sync tab in `SettingsView` between Destinations and About.

## Requirements & known limitations

- Both devices must be on the **same iCloud account with iCloud Keychain enabled**.
- **Known limitation:** turning `iCloudSyncEnabled` off stops payload sync, but secrets already written as synchronizable keychain items continue to ride iCloud Keychain — they are not demoted to local-only items.
- Sync latency is whatever iCloud Keychain propagation takes, plus the next explicit refresh trigger. If another device changes config while ShareMaster is already open and focused, the current device will pick it up when you reopen the macOS popover, activate ShareMaster again, reopen the iOS app, or present the share extension.
