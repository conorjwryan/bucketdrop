//
//  DownloadStore.swift
//  ShareMasterIOS
//
//  Owns the local copies of downloaded objects and the manifest that maps
//  them back to their remote counterparts. Files live under a
//  "ShareMaster Downloads" folder in either Documents (visible in the
//  Files app under On My iPhone → ShareMaster) or Application Support
//  (private), per ConfigStore.showsDownloadsInFilesApp. The manifest always
//  lives in Application Support so it never shows up in the Files app.
//
//  Staleness: each entry records the object's size, lastModified and ETag
//  at download time; state(for:) compares those against a live listing, so
//  a remotely replaced file shows as .outdated rather than silently serving
//  the old bytes.
//

import Foundation
import Observation

enum DownloadState {
    case notDownloaded
    /// A local copy exists and matches the listed object.
    case downloaded
    /// A local copy exists but the remote object has changed since.
    case outdated
}

@MainActor @Observable
final class DownloadStore {
    static let shared = DownloadStore()

    private struct Entry: Codable {
        var size: Int64
        var lastModified: Date
        var etag: String?
        /// Path relative to the downloads root (bucket/key).
        var relativePath: String
        var downloadedAt: Date
    }

    /// Keyed by accountId|bucket|key so the same object browsed via two
    /// destinations shares one download.
    private var entries: [String: Entry] = [:]
    /// Bumped on every mutation so SwiftUI rows re-evaluate their badges.
    private(set) var revision = 0

    private static let folderName = "ShareMaster Downloads"
    private static let manifestName = "downloads.json"

    private init() {
        loadManifest()
    }

    // MARK: - Locations

    private nonisolated static var documentsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private nonisolated static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private nonisolated static var manifestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(manifestName)
    }

    private var root: URL {
        ConfigStore.shared.showsDownloadsInFilesApp ? Self.documentsRoot : Self.supportRoot
    }

    private func entryKey(for object: S3Object, destination: Destination) -> String {
        "\(destination.accountId.uuidString)|\(destination.bucket)|\(object.key)"
    }

    // MARK: - Queries

    func state(for object: S3Object, destination: Destination) -> DownloadState {
        guard let entry = entries[entryKey(for: object, destination: destination)],
              FileManager.default.fileExists(atPath: fileURL(for: entry).path) else {
            return .notDownloaded
        }
        // ETag is the strongest signal when both sides have one; otherwise
        // fall back to size + timestamp (compared at second precision — S3
        // dates carry no sub-second component worth trusting).
        if let local = entry.etag, let remote = object.etag {
            return local == remote ? .downloaded : .outdated
        }
        let sameDate = abs(entry.lastModified.timeIntervalSince(object.lastModified)) < 1
        return entry.size == object.size && sameDate ? .downloaded : .outdated
    }

    /// The local file for an object, nil when not downloaded.
    func localURL(for object: S3Object, destination: Destination) -> URL? {
        guard let entry = entries[entryKey(for: object, destination: destination)] else { return nil }
        let url = fileURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Total bytes of all downloaded files, for the Settings footer.
    var totalSize: Int64 {
        _ = revision
        return entries.values.reduce(0) { sum, entry in
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(for: entry).path)
            return sum + ((attrs?[.size] as? Int64) ?? 0)
        }
    }

    var isEmpty: Bool {
        _ = revision
        return entries.isEmpty
    }

    private func fileURL(for entry: Entry) -> URL {
        root.appendingPathComponent(entry.relativePath)
    }

    // MARK: - Mutations

    /// Moves a freshly downloaded temp file into the store and records it.
    func record(tempURL: URL, object: S3Object, destination: Destination) throws {
        let relativePath = destination.bucket + "/" + object.key
        let target = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: tempURL, to: target)
        entries[entryKey(for: object, destination: destination)] = Entry(
            size: object.size,
            lastModified: object.lastModified,
            etag: object.etag,
            relativePath: relativePath,
            downloadedAt: Date()
        )
        saveManifest()
    }

    /// Removes the local copy (remote object untouched).
    func remove(for object: S3Object, destination: Destination) {
        let key = entryKey(for: object, destination: destination)
        guard let entry = entries[key] else { return }
        try? FileManager.default.removeItem(at: fileURL(for: entry))
        pruneEmptyDirectories(from: fileURL(for: entry).deletingLastPathComponent())
        entries[key] = nil
        saveManifest()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: Self.documentsRoot)
        try? FileManager.default.removeItem(at: Self.supportRoot)
        entries = [:]
        saveManifest()
    }

    /// Migrates existing downloads when showsDownloadsInFilesApp flips.
    /// Called by the Settings toggle *after* the setting changes; relative
    /// paths stay valid because they're anchored to whichever root is
    /// current.
    func applyRootChange() {
        let (from, to) = ConfigStore.shared.showsDownloadsInFilesApp
            ? (Self.supportRoot, Self.documentsRoot)
            : (Self.documentsRoot, Self.supportRoot)
        guard FileManager.default.fileExists(atPath: from.path) else {
            revision += 1
            return
        }
        do {
            if FileManager.default.fileExists(atPath: to.path) {
                // Both roots have content (shouldn't happen in practice) —
                // merge file by file rather than clobbering the folder.
                for entry in entries.values {
                    let source = from.appendingPathComponent(entry.relativePath)
                    let target = to.appendingPathComponent(entry.relativePath)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.moveItem(at: source, to: target)
                }
                try? FileManager.default.removeItem(at: from)
            } else {
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: from, to: to)
            }
        } catch {
            // Files that failed to move simply read as not-downloaded from
            // the new root; nothing is lost in the old one.
        }
        revision += 1
    }

    /// Walks up from a deleted file's folder removing now-empty directories,
    /// so the Files app doesn't accumulate hollow bucket/key folders.
    private func pruneEmptyDirectories(from directory: URL) {
        var dir = directory
        let rootPath = root.path
        while dir.path.hasPrefix(rootPath), dir.path != rootPath {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                  contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: dir)
            dir.deleteLastPathComponent()
        }
    }

    // MARK: - Manifest

    private func loadManifest() {
        guard let data = try? Data(contentsOf: Self.manifestURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func saveManifest() {
        revision += 1
        do {
            try FileManager.default.createDirectory(
                at: Self.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: Self.manifestURL, options: .atomic)
        } catch {
            // Worst case the manifest is stale on next launch and files read
            // as not-downloaded; they remain reachable via the Files app.
        }
    }
}
