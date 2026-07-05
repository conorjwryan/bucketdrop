# ShareMaster Documentation

ShareMaster is a macOS menu-bar utility and iOS app (with a share extension) for uploading files to S3-compatible storage (Cloudflare R2, AWS S3, MinIO, …) and getting a shareable link in one motion.

These docs describe how the codebase is organised, how the three app targets work, how they share an engine and sync configuration between devices, and the conventions/gotchas that matter when changing the code.

## Contents

| Doc | What it covers |
|---|---|
| [Architecture](architecture.md) | Targets, the `Shared/` engine, the Accounts/Destinations data model, `ConfigStore`, where everything is stored |
| [Transfer engine](transfer-engine.md) | `S3Service` (SigV4, multipart upload, ranged download), `RateLimiter` bandwidth caps, `NamingTemplate` |
| [Provider policies](provider_policies.md) | How AWS S3 and Cloudflare R2 differ — S3-spec subsets, listing-order guarantees, what LIST/GET/egress cost, ACL behaviour — and which claims are verified per provider |
| [Sync](sync.md) | How config + credentials sync between macOS and iOS via iCloud Keychain, refresh/polling triggers, per-device settings, known limitations |
| [macOS app](macos.md) | Menu-bar popover, drag-and-drop (including drag onto the menu bar icon), lazy popover lifecycle, Settings window, per-destination download locations |
| [iOS app & share extension](ios.md) | In-app uploads (`UploadManager`), share-sheet uploads, offline downloads (`DownloadStore`/`DownloadManager`, Files-app visibility, export), App Group storage, mobile-data gating, hidden destinations ("decoy mode") |
| [Development](development.md) | Build commands, signing, project conventions (synchronized folders, MainActor default, optional Codable fields), debugging gotchas |

## The one-paragraph mental model

There are **three targets** — the macOS menu-bar app (`ShareMaster/`), the iOS app (`ShareMasterIOS/`), and the iOS share extension (`ShareMasterShareExt/`) — all compiled against the same platform-neutral engine in `Shared/`. The engine is four files: `ConfigStore` (observable config singleton: accounts, destinations, settings, keychain, iCloud sync), `S3Service` (stateless actor doing hand-rolled SigV4 requests, multipart uploads, ranged downloads, bucket listing, presigned links), `RateLimiter` (token-bucket bandwidth caps), and `NamingTemplate` (rename-on-upload tokens). Users configure **Accounts** (credentials) and **Destinations** (account + bucket + prefix + naming + link options); destinations are what you upload *to*. Config and secrets sync across devices through **iCloud Keychain** (no CloudKit — the signing team is a free personal team), with each app polling/refreshing because the keychain posts no change notifications.
