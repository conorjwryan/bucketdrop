# Transfer engine

All networking lives in `Shared/S3Service.swift`, a **stateless actor** with a hand-rolled AWS Signature V4 implementation (`signRequest` accepts arbitrary method/query/headers/payload — the same signer backs uploads, downloads, listing, delete, and presigned links). There is no AWS SDK dependency.

## Uploads

- **Small files (< 32 MiB)**: single signed PUT via `uploadWholeFile`, using `URLSession.upload(for:from:)`. (Note: don't also set `request.httpBody` on that path — a duplicated body triggers a CFNetwork runtime warning; this was a real bug.)
- **Large files (≥ 32 MiB)**: S3 multipart upload with uniform **16 MiB parts** — CreateMultipartUpload → UploadPart × N → CompleteMultipartUpload, with AbortMultipartUpload on failure. Parts run in a **sliding-window TaskGroup** capped by `maxConcurrentParts`; each part is SHA256-signed individually and read through its own per-task `FileHandle`, so a file is never fully loaded into memory.

## Listing & folder navigation

Two ListObjectsV2 entry points:

- `listObjects(config:)` — flat listing under the destination's prefix (up to 50 keys), sorted newest-first. Backs the macOS recents list and the settings connection test.
- `listDirectory(config:prefix:continuationToken:pageSize:)` — one "directory" level at a time for the iOS bucket browser. Sends `delimiter=/` so S3 groups deeper keys into `CommonPrefixes` (returned as `S3Folder`s) server-side, and pages `pageSize` (default 10) entries per request via `max-keys` + continuation token. **Each page costs exactly one LIST request** — S3 bills per request, not per key, so small pages mean you only pay for what the user actually scrolls to. Results keep S3's lexicographic order; don't re-sort in the service — continuation pagination depends on the order staying stable across pages. (The iOS browser's non-ascending sort orders fetch *all* pages first and only sort the completed set client-side — see [iOS](ios.md#bucket-browser-folders-sorting-paging-permissions).)

Signing gotcha: the query string goes into the SigV4 canonical request **verbatim**, so parameters must be assembled in alphabetical order (`continuation-token`, `delimiter`, `list-type`, `max-keys`, `prefix`).

### Creating folders

`createFolder(named:under:config:)` makes an empty "folder" appear by writing a hidden zero-byte object at `<prefix><name>/.folder_placeholder` (key name in `S3Service.folderPlaceholderName`). The AWS-console convention — a bare zero-byte `name/` marker — **doesn't work on R2**, which returns it in `Contents` instead of rolling it into `CommonPrefixes`; any key *under* the prefix forces every S3 implementation to report the folder. Both list parsers hide placeholder keys (along with `/`-suffixed markers), so inside a fresh folder the app shows an empty listing — but the placeholder **is visible in the provider's own dashboard**. Delete everything in a folder including its placeholder and the folder disappears; that's normal prefix semantics, not a bug.

## Errors

`s3Error()` translates the XML `<Code>`/`<Message>` body into a friendly message, and `S3Error` carries the raw `code` alongside it. `S3Error.isPermissionIssue` groups the credential/policy family (`AccessDenied`, `AllAccessDisabled`, `AccountProblem`, `InvalidAccessKeyId`, `SignatureDoesNotMatch`; a 403 with an unparseable body counts as `AccessDenied`) so UI can show permission-specific guidance — see the iOS browser's warning-triangle state.

## Downloads

Concurrent **ranged download**: HEAD for the object size, preallocate a `.partial` file, fetch byte ranges in parallel, and fall back to a sequential download if the server doesn't answer 206. Used by the macOS recents download button (the iOS app currently has no file-download feature — it browses and copies links).

## Bandwidth caps

`Shared/RateLimiter.swift` is a **debt-based token-bucket actor**. Caps come from the resolved `S3Config` (per-destination override → account default → uncapped). Downloads throttle per 64 KiB chunk; uploads throttle per part. Verified against R2: 1 MB/s caps pace a 12.6 MiB transfer to ~13–19 s vs ~2–5 s uncapped, with byte-identical roundtrips.

## Progress

Per-part/per-range progress aggregates through the `TransferProgress` actor into the single-`Double` (0…1) callback the UIs expect — UI code never sees parts or ranges.

## Naming templates

`Shared/NamingTemplate.swift` expands the destination's template into the object key at upload time. The key is `(keyPrefix ?? config.pathPrefix) + expanded template` — `upload(fileURL:config:keyPrefix:)` takes an optional prefix override so the iOS browser can upload into the folder currently open instead of the destination's configured prefix (`""` targets the bucket root; nil means the configured prefix). Tokens:

| Token | Meaning |
|---|---|
| `{filename}` / `{name}` | original name without extension |
| `{.ext}` | dot + extension, empty string if the file has none |
| `{ext}` | extension without the dot |
| `{uuid}` | random UUID |
| `{date}` / `{time}` / `{datetime}` | timestamp components |

The default template is `{filename}{.ext}` (i.e. keep the original name). It used to be `{uuid}-{name}`; destinations created before the change deliberately kept their old template.

## Misc behaviours

- `parseListResponse`/`parseDirectoryResponse` skip keys ending in `/` — zero-byte S3 "directory marker" objects would otherwise show up as bogus entries in recents/browsing.
- `S3Config.allowsCellular` is applied (`URLRequest.allowsCellularAccess`) on the five upload-path requests, backing the iOS mobile-data gate (see [iOS doc](ios.md#mobile-data-gating)).
- Concurrency note: the project defaults everything to MainActor (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so pure helpers called from inside the `S3Service` actor must be marked `nonisolated` (e.g. `NamingTemplate`, the hex-string helpers, `S3Config.isConfigured`) or they'll silently land on MainActor.
