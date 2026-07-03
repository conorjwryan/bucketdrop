# ShareMaster

ShareMaster is a macOS menu bar utility (and iOS app) for uploading files to S3-compatible storage (Cloudflare R2, AWS S3, etc) and getting a sharable link in one motion.

## Features

- Upload files via ShareMaster and receive sharable links (public or presigned) in one motion
- Multiple accounts and destinations (bucket + path prefix + naming template + link options) built to work around you
- Customisable naming templates for renaming files automatically on upload using variables (`{filename}`, `{uuid}`, `{date}`, `{time}`, and more)
- Multipart uploads and concurrent ranged downloads with configurable parallelism
- Optional upload/download bandwidth caps, set per account with per-destination overrides
- Quick Look preview, download, and delete for recent uploads
- Per-destination download folders
- Credentials stored in the Keychain and synced through iCloud (keeping your credentials secure and accessible across all your devices)
- Works with AWS S3, Cloudflare R2, MinIO, and other S3-compatible storage providers.

### MacOS

- Drag & drop onto the menu bar icon — the popover opens mid-drag so you can drop straight onto a destination
- Lightweight footprint — the popover loads on demand and releases memory when idle so it's not using up resources when you're not using it

### iOS

The iOS app has the same features as the MacOS app, where opening the app allows you to view destinations and download files, but main focus of the iOS app is being unobtrusive to your workflow by allowing you to upload files through the Share Sheet.

## Note on Installation

I do not have an Apple Developer Subscription, as such to run either the MacOS or iOS apps you're going to have to download and compile this yourself.

This will hopefully change in the future but yeah but you'll probably get a bunch of notisation / security errors as a result.

## Setup

While these setup instructions are for the MacOS app, the same process applies for the iOS app.

The good news is that once you have them set up on one system through iCloud sync they'll be available on all your devices.

### MacOS Setup

1. Click the ShareMaster icon in the menu bar
2. Click the gear icon to open Settings
3. Add an **Account** (credentials): Access Key ID, Secret Access Key, Region (`auto` for Cloudflare R2), and an S3 endpoint for non-AWS services
4. Add a **Destination**: pick the account, set the bucket, optional path prefix, naming template, and link mode (public or presigned)

## Requirements

- macOS 14.0 (Sonoma) or later
- iOS/iPadOS 17.0 or later

## Acknowledgements

ShareMaster is developed by [Conor Ryan](https://cjwr.dev), built on the foundation of [BucketDrop](https://github.com/fayazara/bucketdrop) by [Fayaz Ahmed](https://x.com/fayazara).
