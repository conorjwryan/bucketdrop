//
//  ShareUploadView.swift
//  ShareMasterShareExt
//
//  The whole share-sheet flow: attachments load in the background while the
//  destination list shows; tapping a destination uploads everything to it,
//  puts the resulting link(s) on the clipboard, flashes a confirmation and
//  dismisses the sheet.
//

import SwiftUI
import UniformTypeIdentifiers

struct ShareUploadView: View {
    let extensionItems: [NSExtensionItem]
    let onFinish: (Error?) -> Void

    private enum Phase {
        case pickingDestination
        case uploading(destination: String)
        case done(linkCount: Int)
        case failed(String)
    }

    @State private var phase: Phase = .pickingDestination
    @State private var progress: Double = 0
    @State private var loadedFiles: [URL]?   // nil while attachments still load
    private let config = ConfigStore.shared

    /// Hidden destinations never appear in the share sheet — they're only
    /// reachable from inside the app.
    private var visibleDestinations: [Destination] {
        config.sortedDestinations.filter { !$0.isHidden }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ShareMaster")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if case .pickingDestination = phase {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { onFinish(nil) }
                        }
                    }
                }
        }
        .task { await loadAttachments() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .pickingDestination:
            destinationPicker
        case .uploading(let destination):
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 32)
                Text("Uploading to \(destination)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let linkCount):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text(linkCount == 1
                     ? "File uploaded and link copied to clipboard"
                     : "\(linkCount) files uploaded and links copied to clipboard")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Upload Failed", systemImage: "exclamationmark.icloud")
            } description: {
                Text(message)
            } actions: {
                Button("Close") { onFinish(nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var destinationPicker: some View {
        Group {
            if visibleDestinations.isEmpty {
                ContentUnavailableView(
                    "No Destinations",
                    systemImage: "tray.and.arrow.up",
                    description: Text("Set up an account and destination in the ShareMaster app first.")
                )
            } else {
                List {
                    Section(loadedFiles == nil ? "Preparing files…" : sectionTitle) {
                        ForEach(visibleDestinations) { destination in
                            Button {
                                upload(to: destination)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "externaldrive.badge.icloud")
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(destination.name.isEmpty ? destination.bucket : destination.name)
                                            .foregroundStyle(.primary)
                                        Text(destination.bucket)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if destination.id == config.lastSelectedDestinationID {
                                        Text("Last used")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(loadedFiles == nil)
                        }
                    }
                }
            }
        }
    }

    private var sectionTitle: String {
        let count = loadedFiles?.count ?? 0
        return count == 1 ? "Upload 1 file to" : "Upload \(count) files to"
    }

    // MARK: - Attachment loading

    private func loadAttachments() async {
        var urls: [URL] = []
        for item in extensionItems {
            for provider in item.attachments ?? [] {
                if let url = await AttachmentLoader.loadFile(from: provider) {
                    urls.append(url)
                }
            }
        }
        if urls.isEmpty {
            phase = .failed("Nothing shareable was received.")
        } else {
            loadedFiles = urls
        }
    }

    // MARK: - Upload

    private func upload(to destination: Destination) {
        guard let files = loadedFiles, !files.isEmpty else { return }
        guard let s3Config = config.s3Config(for: destination) else {
            phase = .failed("This destination's account is missing its credentials.")
            return
        }
        config.lastSelectedDestinationID = destination.id
        phase = .uploading(destination: destination.name.isEmpty ? destination.bucket : destination.name)

        Task {
            do {
                var links: [String] = []
                for (index, file) in files.enumerated() {
                    let result = try await S3Service.shared.upload(fileURL: file, config: s3Config) { fileProgress in
                        Task { @MainActor in
                            progress = (Double(index) + fileProgress) / Double(files.count)
                        }
                    }
                    links.append(result.url)
                }

                UIPasteboard.general.string = links.joined(separator: "\n")
                phase = .done(linkCount: links.count)
                try? await Task.sleep(for: .seconds(1.2))
                onFinish(nil)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - AttachmentLoader

/// Turns an NSItemProvider into a real file in the extension's tmp directory.
/// Screenshots may arrive as in-memory images with no file representation, so
/// there is a UIImage/Data fallback that writes a timestamped PNG.
enum AttachmentLoader {
    static func loadFile(from provider: NSItemProvider) async -> URL? {
        // Preferred: a file representation of whatever the provider holds.
        for type in [UTType.image, .movie, .fileURL, .data] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if type == .fileURL {
                if let url = try? await loadURL(from: provider), url.isFileURL {
                    return copyToTemp(url)
                }
                continue
            }
            if let url = try? await loadFileRepresentation(from: provider, type: type) {
                return url
            }
        }

        // Fallback: an in-memory image (typical for freshly-taken screenshots).
        if provider.canLoadObject(ofClass: UIImage.self),
           let image = try? await loadImage(from: provider),
           let data = image.pngData() {
            let name = suggestedFilename(provider, fallbackExt: "png")
            let url = tempURL(filename: name)
            try? data.write(to: url)
            return url
        }
        return nil
    }

    private static func loadFileRepresentation(from provider: NSItemProvider, type: UTType) async throws -> URL {
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                    return
                }
                // The provided URL dies when this handler returns — copy it out,
                // preferring the provider's suggested name for nicer object keys.
                var filename = url.lastPathComponent
                if let suggested, !suggested.isEmpty {
                    let ext = url.pathExtension
                    filename = (suggested as NSString).pathExtension.isEmpty && !ext.isEmpty
                        ? "\(suggested).\(ext)" : suggested
                }
                let dest = tempURL(filename: filename)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                }
            }
        }
    }

    private static func loadImage(from provider: NSItemProvider) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { image, error in
                if let image = image as? UIImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile))
                }
            }
        }
    }

    private static func suggestedFilename(_ provider: NSItemProvider, fallbackExt: String) -> String {
        if let name = provider.suggestedName, !name.isEmpty {
            return (name as NSString).pathExtension.isEmpty ? "\(name).\(fallbackExt)" : name
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: Date())).\(fallbackExt)"
    }

    /// A unique per-share temp location so identically-named files don't clash.
    private static func tempURL(filename: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    private static func copyToTemp(_ url: URL) -> URL? {
        let dest = tempURL(filename: url.lastPathComponent)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
