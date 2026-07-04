# Cross-device sync

Config (accounts, destinations, settings) and credentials sync between macOS and iOS through **iCloud Keychain only**. There is no CloudKit and no iCloud key-value store: the signing team (`HU9TH52NNC`) is a free personal Apple Developer team, which cannot enable those capabilities. All sync logic lives in `Shared/ConfigStore.swift`.

## Mechanism

- All per-account secrets **and** a whole-config JSON payload (keychain item `cloud_config_payload`) are stored as `kSecAttrSynchronizable` keychain items in the shared access group `HU9TH52NNC.com.cjwr.ShareMaster.sync`. The entitlement `$(AppIdentifierPrefix)com.cjwr.ShareMaster.sync` is present in all three targets; on macOS the queries additionally need `kSecUseDataProtectionKeychain`.
- Conflict resolution is **last-writer-wins**: the payload carries an `updatedAt` timestamp compared against the locally stored `config_cloud_updated_at`; `adoptCloudIfNewer()` bails when the versions match (so polling is cheap — one keychain read).
- Every local mutation calls `pushToCloud()` (guarded by `isAdoptingCloud` so adopting a remote payload doesn't immediately re-push it).

## Refresh triggers (there are no keychain change notifications)

Apple's keychain posts no change events, so every surface refreshes explicitly:

| Surface | Trigger |
|---|---|
| macOS popover | `refreshFromCloud()` in the content `.task` on each open, **plus a 5-second poll loop while the popover is open** (cancelled on close) |
| macOS Settings window | `refreshFromCloud()` on appear + poll while open |
| iOS app | `refreshFromCloud()` when `scenePhase` becomes active, plus a poll loop while active (`DestinationListView`) |
| Share extension | `ConfigStore` init adopts the cloud payload; `reloadFromDefaults()` on each presentation because the extension process is reused |

## Migration & fallbacks

Legacy keychain items (macOS login keychain from the pre-sync era, iOS app-group items) are read-through-migrated into the sync group on first access. `keychainSet` falls back to legacy storage on `errSecMissingEntitlement` so unsigned/dev builds without the sync entitlement still work.

## Device-local settings (deliberately NOT synced)

`iCloudSyncEnabled` (default on), `allowsCellularUploads` (default on), and `suppressCellularWarnings` (default off) are per-device UserDefaults and excluded from the synced payload — turning sync off on one device must not propagate, and cellular preferences are inherently per-device. `iCloudSyncEnabled` gates `startCloudSync`/`pushToCloud`/`adoptCloudIfNewer`; re-enabling it adopts the cloud payload first, then pushes.

Settings UI: iOS has a Sync section in `IOSSettingsView` (three toggles; "suppress warnings" is disabled unless cellular uploads are allowed); macOS has a Sync tab in `SettingsView` between Destinations and About.

## Requirements & known limitations

- Both devices must be on the **same iCloud account with iCloud Keychain enabled**.
- **Known limitation:** turning `iCloudSyncEnabled` off stops payload sync, but secrets already written as synchronizable keychain items continue to ride iCloud Keychain — they are not demoted to local-only items.
- Sync latency is whatever iCloud Keychain propagation takes; the 5 s polls only detect a payload that has already arrived on-device.
