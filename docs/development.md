# Development guide

Conventions, build commands, and hard-won gotchas. Written for both humans and coding agents.

## Building

```sh
# macOS app
xcodebuild -project ShareMaster.xcodeproj -scheme ShareMaster \
  -configuration Debug -destination 'platform=macOS' build

# iOS app (simulator)
xcodebuild -project ShareMaster.xcodeproj -scheme ShareMasterIOS \
  -destination 'generic/platform=iOS Simulator' build

# Relaunch the freshly built Mac app
pkill -x ShareMaster; open ~/Library/Developer/Xcode/DerivedData/ShareMaster-*/Build/Products/Debug/ShareMaster.app
```

The build is **zero-warning** — keep it that way. Pass `-allowProvisioningUpdates` if provisioning errors appear.

## Signing

Debug builds sign with the developer's **Apple Development certificate**. Do **not** reintroduce an ad-hoc `CODE_SIGN_IDENTITY = "-"` override — ad-hoc re-signing invalidates keychain access and caused a keychain prompt on every rebuild. The team (`HU9TH52NNC`) is a free personal team: no CloudKit/KVS capabilities (which is why sync rides iCloud Keychain — see [Sync](sync.md)), no notarised distribution.

## Project conventions

- **Synchronized folders** (objectVersion 77): new `.swift` files in `Shared/`, `ShareMaster/`, `ShareMasterIOS/`, or `ShareMasterShareExt/` are picked up automatically. Don't add stray non-source files to those folders — they'd be bundled as resources (an empty `Info.plist` once caused a build warning this way; the targets use `GENERATE_INFOPLIST_FILE` + `INFOPLIST_KEY_*` settings).
- **MainActor by default**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` project-wide. Any pure helper called from an actor (notably `S3Service`) must be explicitly `nonisolated`, or it silently hops to MainActor.
- **Codable evolution**: new stored fields on `Account`/`Destination`/settings must be optionals decoded with `decodeIfPresent`; old JSON (local and synced from other devices) must keep decoding. Default-on Bool settings need the `defaults.object(forKey:) != nil` guard.
- **Settings window (macOS)**: always open via `@Environment(\.openSettings)` / the `Settings` scene. Don't build a custom NSWindow.
- **iOS presentations**: upload alerts and `UploadStatusBar` attach to the NavigationStack, not the root list — see [iOS doc](ios.md).
- `.gitignore` covers `.build/`, `xcuserdata/`, `DerivedData/`, `.DS_Store`. A 64 MB SourceKit index was once committed — don't let build artefacts back in.

## Debugging gotchas

- **SourceKit single-file diagnostics are noise in this repo** (constant "Cannot find type in scope"). Trust `xcodebuild` output, not editor diagnostics.
- **Don't measure memory/energy under the Xcode debugger** — attached apps show inflated numbers, `pkill` won't kill them, and killing the `debugserver` can wedge Xcode (force-quit territory) while the app dies silently with no crash report. Launch with `open` and check `ps -o ppid=` (parent should be launchd) before profiling.
- **Wireless deploy to a physical iPhone** often launches to a white/frozen screen — the process starts suspended waiting for debugserver over Wi-Fi. It's tooling, not app code: kill and reopen the app manually, use a cable, or Edit Scheme → Run → uncheck "Debug executable".

## Verifying transfers

The transfer engine was validated end-to-end against Cloudflare R2 with a throwaway CLI harness compiled from the app's own `Shared/` sources (env vars for access key / secret / endpoint / source / destination): multipart + ranged roundtrips byte-identical, bandwidth caps pacing as expected. If you change `S3Service` or `RateLimiter`, re-verify the same way rather than trusting unit-level reasoning — SigV4 and range math fail quietly.

## Things that don't exist (don't go looking)

- No Import/Export or CyberDuck-compatibility feature.
- No background `URLSession` on iOS (deliberately deferred — uploads get a ~30 s background-task grace, then suspend).
- No file downloads in the iOS app (browse + copy link only).
- No tests target as of 2026-07-04.
