# Transfer engine

All networking lives in `Shared/S3Service.swift`, a **stateless actor** with a hand-rolled AWS Signature V4 implementation (`signRequest` accepts arbitrary method/query/headers/payload — the same signer backs uploads, downloads, listing, delete, and presigned links). There is no AWS SDK dependency.

## Uploads

- **Small files (< 32 MiB)**: single signed PUT via `uploadWholeFile`, using `URLSession.upload(for:from:)`. (Note: don't also set `request.httpBody` on that path — a duplicated body triggers a CFNetwork runtime warning; this was a real bug.)
- **Large files (≥ 32 MiB)**: S3 multipart upload with uniform **16 MiB parts** — CreateMultipartUpload → UploadPart × N → CompleteMultipartUpload, with AbortMultipartUpload on failure. Parts run in a **sliding-window TaskGroup** capped by `maxConcurrentParts`; each part is SHA256-signed individually and read through its own per-task `FileHandle`, so a file is never fully loaded into memory.

## Downloads

Concurrent **ranged download**: HEAD for the object size, preallocate a `.partial` file, fetch byte ranges in parallel, and fall back to a sequential download if the server doesn't answer 206. Used by the macOS recents download button (the iOS app currently has no file-download feature — it browses and copies links).

## Bandwidth caps

`Shared/RateLimiter.swift` is a **debt-based token-bucket actor**. Caps come from the resolved `S3Config` (per-destination override → account default → uncapped). Downloads throttle per 64 KiB chunk; uploads throttle per part. Verified against R2: 1 MB/s caps pace a 12.6 MiB transfer to ~13–19 s vs ~2–5 s uncapped, with byte-identical roundtrips.

## Progress

Per-part/per-range progress aggregates through the `TransferProgress` actor into the single-`Double` (0…1) callback the UIs expect — UI code never sees parts or ranges.

## Naming templates

`Shared/NamingTemplate.swift` expands the destination's template into the object key at upload time. Tokens:

| Token | Meaning |
|---|---|
| `{filename}` / `{name}` | original name without extension |
| `{.ext}` | dot + extension, empty string if the file has none |
| `{ext}` | extension without the dot |
| `{uuid}` | random UUID |
| `{date}` / `{time}` / `{datetime}` | timestamp components |

The default template is `{filename}{.ext}` (i.e. keep the original name). It used to be `{uuid}-{name}`; destinations created before the change deliberately kept their old template.

## Misc behaviours

- `parseListResponse` skips keys ending in `/` — zero-byte S3 "directory marker" objects would otherwise show up as bogus entries in recents/browsing.
- `S3Config.allowsCellular` is applied (`URLRequest.allowsCellularAccess`) on the five upload-path requests, backing the iOS mobile-data gate (see [iOS doc](ios.md#mobile-data-gating)).
- Concurrency note: the project defaults everything to MainActor (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so pure helpers called from inside the `S3Service` actor must be marked `nonisolated` (e.g. `NamingTemplate`, the hex-string helpers, `S3Config.isConfigured`) or they'll silently land on MainActor.
