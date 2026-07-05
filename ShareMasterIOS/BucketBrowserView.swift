//
//  BucketBrowserView.swift
//  ShareMasterIOS
//
//  Lists one folder level of a destination's bucket (under its path
//  prefix), 10 entries per page. "Folders" are S3 CommonPrefixes — tap
//  one to drill in; tap a file row for a preview + actions; swipe or
//  context menu for quick copy-link and delete.
//

import SwiftUI
import ImageIO

struct BucketBrowserView: View {
    let destination: Destination
    /// The key prefix this view lists. `nil` means the destination root
    /// (its configured path prefix); subfolders push new instances.
    var prefix: String? = nil

    private static let pageSize = 10

    @State private var folders: [S3Folder] = []
    @State private var objects: [S3Object] = []
    @State private var nextToken: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var selectedObject: S3Object?
    @State private var copiedKey: String?

    private var config: S3Config? {
        ConfigStore.shared.s3Config(for: destination)
    }

    private var listPrefix: String {
        prefix ?? config?.pathPrefix ?? ""
    }

    private var isEmpty: Bool {
        folders.isEmpty && objects.isEmpty
    }

    private var title: String {
        if let prefix {
            let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            return (trimmed as NSString).lastPathComponent
        }
        return destination.name.isEmpty ? destination.bucket : destination.name
    }

    var body: some View {
        Group {
            if isLoading && isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "exclamationmark.icloud")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await refresh() } }
                }
            } else if isEmpty {
                ContentUnavailableView(
                    "Empty",
                    systemImage: "tray",
                    description: Text("No files in this folder yet.")
                )
            } else {
                objectList
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                UploadMenu(destination: destination) {
                    Task { await refresh() }
                }
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(item: $selectedObject) { object in
            ObjectDetailView(object: object, destination: destination) {
                objects.removeAll { $0.key == object.key }
            }
        }
    }

    private var objectList: some View {
        List {
            ForEach(folders) { folder in
                NavigationLink {
                    BucketBrowserView(destination: destination, prefix: folder.prefix)
                } label: {
                    FolderRow(folder: folder)
                }
            }

            ForEach(objects) { object in
                Button {
                    selectedObject = object
                } label: {
                    ObjectRow(object: object, copied: copiedKey == object.key)
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await delete(object) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        Task { await copyLink(object) }
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button {
                        Task { await copyLink(object) }
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    Button(role: .destructive) {
                        Task { await delete(object) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            if nextToken != nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .onAppear {
                    Task { await loadMore() }
                }
            }
        }
    }

    private func refresh() async {
        guard let config else {
            errorMessage = "Destination not configured"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await S3Service.shared.listDirectory(
                config: config, prefix: listPrefix, pageSize: Self.pageSize
            )
            folders = page.folders
            objects = page.objects
            nextToken = page.nextContinuationToken
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let config, let token = nextToken, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await S3Service.shared.listDirectory(
                config: config, prefix: listPrefix,
                continuationToken: token, pageSize: Self.pageSize
            )
            folders.append(contentsOf: page.folders)
            objects.append(contentsOf: page.objects)
            nextToken = page.nextContinuationToken
        } catch {
            // Keep what's loaded; a retry happens if the spinner reappears.
            nextToken = token
        }
    }

    private func copyLink(_ object: S3Object) async {
        guard let config else { return }
        if let link = try? await S3Service.shared.shareLink(for: object.key, config: config) {
            UIPasteboard.general.string = link
            copiedKey = object.key
            try? await Task.sleep(for: .seconds(1.5))
            if copiedKey == object.key { copiedKey = nil }
        }
    }

    private func delete(_ object: S3Object) async {
        guard let config else { return }
        do {
            try await S3Service.shared.deleteObject(key: object.key, config: config)
            objects.removeAll { $0.key == object.key }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FolderRow: View {
    let folder: S3Folder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(folder.name)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct ObjectRow: View {
    let object: S3Object
    let copied: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(object.filename)
                    .lineLimit(1)
                Text("\(object.size.formattedFileSize) · \(object.lastModified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if copied {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch (object.key as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": "photo"
        case "mp4", "mov", "m4v", "webm": "video"
        case "mp3", "m4a", "wav", "aac": "waveform"
        case "zip", "gz", "tar", "7z", "rar": "doc.zipper"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }
}

/// Preview sheet: shows the image (when the object is one) and offers
/// copy link / share / delete.
struct ObjectDetailView: View {
    let object: S3Object
    let destination: Destination
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var link: String?
    @State private var copied = false
    @State private var errorMessage: String?

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"]
            .contains((object.key as NSString).pathExtension.lowercased())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isImage, let link, let url = URL(string: link) {
                    RemoteImagePreview(url: url)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }

                VStack(spacing: 4) {
                    Text(object.filename)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("\(object.size.formattedFileSize) · \(object.lastModified.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                VStack(spacing: 10) {
                    Button {
                        if let link {
                            UIPasteboard.general.string = link
                            copied = true
                        }
                    } label: {
                        Label(copied ? "Link Copied" : "Copy Link",
                              systemImage: copied ? "checkmark" : "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(link == nil)

                    if let link, let url = URL(string: link) {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(role: .destructive) {
                        Task { await deleteObject() }
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard let config = ConfigStore.shared.s3Config(for: destination) else { return }
                link = try? await S3Service.shared.shareLink(for: object.key, config: config)
            }
        }
    }

    private func deleteObject() async {
        guard let config = ConfigStore.shared.s3Config(for: destination) else { return }
        do {
            try await S3Service.shared.deleteObject(key: object.key, config: config)
            onDelete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RemoteImagePreview: View {
    let url: URL

    @State private var config = ConfigStore.shared
    @State private var network = NetworkMonitor.shared
    @State private var image: Image?
    @State private var isLoading = false
    @State private var didRequestPreview = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else if let errorMessage {
                previewNotice(title: "Preview unavailable", message: errorMessage)
            } else if isLoading {
                ProgressView()
            } else if shouldWaitForTap {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Image preview")
                        .font(.subheadline.weight(.semibold))
                    Text("This image will download over mobile data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        didRequestPreview = true
                        Task { await load() }
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                previewNotice(title: "Preview unavailable", message: "The image preview could not be loaded.")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            didRequestPreview = false
            if !shouldWaitForTap {
                await load()
            }
        }
    }

    private var shouldWaitForTap: Bool {
        config.requiresTapForCellularPreviews && network.isOnCellular && !didRequestPreview
    }

    private func previewNotice(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func load() async {
        isLoading = true
        image = nil
        errorMessage = nil
        defer { isLoading = false }

        do {
            let request = URLRequest(url: url)
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                errorMessage = "The link returned HTTP \(http.statusCode). Copy the link to check whether the file still exists."
                return
            }

            let uiImage = config.rendersFullImagePreviews
                ? UIImage(data: data)
                : Self.downsampledImage(from: data, maxPixel: 1200)

            guard let uiImage else {
                errorMessage = "The link did not return a supported image."
                return
            }

            image = Image(uiImage: uiImage)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated private static func downsampledImage(from data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

extension Int64 {
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
