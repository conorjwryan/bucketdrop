# Provider policies: S3-compatible platforms

ShareMaster speaks the S3 API to whatever endpoint an account points at — AWS S3, Cloudflare R2, MinIO, and other S3-compatible services. **Providers implement different subsets of the S3 spec and charge for different things**, so anywhere the code or docs make a claim about listing behaviour, request costs, or API features, this page is the reference for which providers that claim has actually been verified against.

Verified against the providers' own documentation on **2026-07-05** (sources at the bottom). AWS S3 and Cloudflare R2 are the two providers the app is actively used and tested with; treat anything else as unverified until checked.

## What the app relies on

The engine (`Shared/S3Service.swift`) depends on a few provider behaviours:

1. **Stable lexicographic listing order** — continuation-token pagination in the bucket browser assumes the order never changes between pages ([Transfer engine](transfer-engine.md#listing--folder-navigation)).
2. **Per-request LIST billing** — the browser's page-size choices assume a LIST costs the same whether it returns 10 keys or 200 ([iOS](ios.md#bucket-browser-folders-sorting-paging-permissions)).
3. **ListObjectsV2 with `delimiter=/`** — folder navigation is CommonPrefixes grouping.
4. **SigV4, multipart upload, presigned URLs** — the core transfer/link machinery.
5. **`x-amz-acl: public-read` on upload** — the "make uploads public" option.

## Listing order

| Provider | ListObjectsV2 order |
|---|---|
| AWS S3 (general purpose buckets) | **Guaranteed lexicographical** by key name — stated explicitly in the API reference. |
| AWS S3 (directory buckets / S3 Express One Zone) | **NOT lexicographical** — AWS documents this explicitly. These buckets also require zonal endpoints and session auth the app doesn't implement, so they're effectively unsupported anyway. |
| Cloudflare R2 | **Lexicographic**, and ListObjectsV2 supports the full parameter set the app uses (`delimiter`, `prefix`, `continuation-token`, `max-keys`, `start-after`). |

Consequence: the browser's lazy Name (A to Z) paging is safe on both AWS (general purpose) and R2. The other sort orders (Recently Uploaded, Name Z to A) can't be paged from any S3 API — no provider offers server-side date or reverse ordering — which is why the browser fetches the whole level and sorts client-side for those.

## What a listing costs

Both AWS and R2 bill list operations **per request, not per key returned** — a LIST returning 200 keys costs exactly the same as one returning 10. On both, a LIST is ~12× the price of a GET.

| | AWS S3 (Standard, us-east-1) | Cloudflare R2 (Standard) |
|---|---|---|
| LIST | $0.005 per 1,000 (billed with PUT/COPY/POST) | Class A: $4.50 per million ($0.0045/1,000) |
| GET | $0.0004 per 1,000 | Class B: $0.36 per million |
| Free tier | none ongoing (12-month trial only) | 1M Class A + 10M Class B per month, every month |
| Egress (data out) | ~$0.09/GB after 100 GB/month free | **$0 — always free** |

Consequences for the app:

- The browser's default 10-per-page lazy listing exists so unbrowsed pages cost nothing — but note the *fetch-all* sort path (200 keys per LIST) is actually **cheaper per key** than 10-per-page, since billing is per request. The lazy path wins only when the user never scrolls.
- **Egress is where the providers really diverge**: image previews, downloads, and anyone opening shared links pull object bytes. On R2 that's free; on AWS it's ~$0.09/GB once past the free allowance. The iOS cellular-preview gating saves the *user's* data plan either way, but only on AWS does it also save the bucket owner money.
- R2's free tier (1M Class A/month) makes browsing effectively free at personal scale; on AWS every LIST is billed, though at $5/million it takes heavy use to notice.

## S3-spec implementation differences

Cloudflare R2 implements a subset of the S3 API. Differences that touch this app:

- **ACLs are not really supported.** R2 now *accepts* `x-amz-acl: public-read` (older R2 rejected it, which broke standard S3 clients — Cloudflare fixed the rejection) but access control doesn't work through ACLs: public access on R2 comes from enabling the bucket's `r2.dev` URL or a custom domain. So the app's "Make uploads public" toggle is meaningful on AWS and effectively a no-op on R2 — on R2 you set the destination's **Public URL base** to the r2.dev/custom domain instead.
- **Empty-folder CommonPrefixes quirk** — the reason `createFolder` writes a hidden placeholder object; see [Transfer engine](transfer-engine.md#creating-folders).
- **Unimplemented on R2** (fine for this app, listed for awareness): object versioning, object tagging, object lock, website redirects, request-payer, and most storage classes (R2 has only Standard and Infrequent Access).

Presigned URLs, SigV4 signing, and multipart upload work the same on both and are verified end-to-end against R2.

## Other providers

MinIO, Backblaze B2, Wasabi, DigitalOcean Spaces, etc. each have their own spec subset and pricing model (some charge nothing per request but impose minimum storage durations; some cap free egress as a multiple of stored data). **None of them have been verified against this app.** Before encoding any provider-specific assumption in code or docs — ordering, billing, header behaviour — check that provider's documentation and add the finding here.

## Sources

- [AWS ListObjectsV2 API reference](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html) — ordering guarantees (general purpose vs directory buckets), max-keys, pagination
- [AWS S3 pricing](https://aws.amazon.com/s3/pricing/) — request and egress rates
- [Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing/) — Class A/B operations, free tier, zero egress
- [Cloudflare R2 S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/) — supported/unsupported operations and headers
- [Cloudflare R2 release notes](https://developers.cloudflare.com/r2/platform/release-notes/) — `x-amz-acl: public-read` no longer rejected; ListObjectsV2 fixes (empty-folder CommonPrefixes, KeyCount)
