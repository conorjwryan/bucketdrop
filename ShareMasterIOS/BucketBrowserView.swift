//
//  BucketBrowserView.swift
//  ShareMasterIOS
//
//  Lists one folder level of a destination's bucket (under its path
//  prefix), 200 entries per page. "Folders" are S3 CommonPrefixes — tap
//  one to drill in; tap a file row for a preview + actions; swipe or
//  context menu for quick copy-link and delete.
//

import SwiftUI
import ImageIO
import QuickLook

struct BucketBrowserView: View {
    let destination: Destination
    /// The key prefix this view lists. `nil` means the destination root
    /// (its configured path prefix); subfolders push new instances.
    var prefix: String? = nil
    /// Whether this level offers an "up" row. `nil` defaults to true only at
    /// the destination root; views pushed via the up row pass true so you can
    /// keep climbing to the bucket root.
    var showsParentLink: Bool? = nil

    /// Both AWS and R2 bill LIST per request, not per key, so a 200-key page
    /// costs the same as a 10-key one — see docs/provider_policies.md. Paging
    /// still exists so enormous folders load incrementally.
    private static let pageSize = 200

    @State private var folders: [S3Folder] = []
    @State private var objects: [S3Object] = []
    @State private var nextToken: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var isPermissionError = false
    @State private var selectedObject: S3Object?
    @State private var copiedKey: String?
    @State private var downloadStore = DownloadStore.shared
    @State private var downloads = DownloadManager.shared
    /// Object awaiting delete confirmation (swipe or context menu).
    @State private var pendingDelete: S3Object?
    /// Downloaded file being exported via the Files document picker.
    @State private var exportItem: ExportItem?
    @State private var showNewDestinationPrompt = false
    @State private var newDestinationName = ""
    @State private var didSaveDestination = false
    @State private var editingDestination: Destination?
    /// Sort picked from the "…" menu for this view only; nil falls back to
    /// the destination's default.
    @State private var sortOverride: BrowserSort?
    /// The sort the current listing was loaded with, so we know whether a
    /// settings change requires a reload.
    @State private var loadedSort: BrowserSort?

    private var config: S3Config? {
        ConfigStore.shared.s3Config(for: destination)
    }

    /// Effective sort: menu override first, then the stored destination's
    /// default (read live so edits made in the settings sheet apply).
    private var sort: BrowserSort {
        sortOverride
            ?? ConfigStore.shared.destinations.first { $0.id == destination.id }?.defaultBrowserSort
            ?? destination.defaultBrowserSort
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
            let name = (trimmed as NSString).lastPathComponent
            return name.isEmpty ? destination.bucket : name
        }
        return destination.name.isEmpty ? destination.bucket : destination.name
    }

    /// The prefix one level above this view, or nil when there's nowhere to
    /// go. Offered at the destination root and on views reached via the up
    /// row — folder drill-downs already have the back button.
    /// "shots/" → "", "a/b/" → "a/".
    private var parentPrefix: String? {
        guard showsParentLink ?? (prefix == nil), !listPrefix.isEmpty else { return nil }
        let trimmed = listPrefix.hasSuffix("/") ? String(listPrefix.dropLast()) : listPrefix
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent + "/"
    }

    private var parentName: String {
        guard let parentPrefix, !parentPrefix.isEmpty else { return destination.bucket }
        return (String(parentPrefix.dropLast()) as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            if isLoading && isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, isEmpty {
                if isPermissionError {
                    ContentUnavailableView {
                        Label {
                            Text("Permission Denied")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    } description: {
                        Text("This account isn't allowed to list this location. Check the account's credentials and that its IAM or bucket policy grants s3:ListBucket here.\n\n\(errorMessage)")
                    } actions: {
                        Button("Retry") { Task { await refresh() } }
                    }
                } else {
                    ContentUnavailableView {
                        Label("Couldn't Load", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await refresh() } }
                    }
                }
            } else if isEmpty && parentPrefix == nil {
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                UploadMenu(destination: destination, keyPrefix: listPrefix) {
                    Task { await refresh() }
                }
                Menu {
                    Picker("Sort By", selection: Binding(
                        get: { sort },
                        set: { sortOverride = $0 }
                    )) {
                        ForEach(BrowserSort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    Divider()

                    if let existing = destinationAtThisPrefix {
                        Button {
                            editingDestination = existing
                        } label: {
                            Label("View Destination Settings", systemImage: "slider.horizontal.3")
                        }
                    } else {
                        Button {
                            let names = ConfigStore.shared.destinations.map(\.name)
                            newDestinationName = names.contains(suggestedDestinationName)
                                ? ConfigStore.copyName(suggestedDestinationName, existing: names)
                                : suggestedDestinationName
                            showNewDestinationPrompt = true
                        } label: {
                            Label("New Destination Here", systemImage: "externaldrive.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("New Destination", isPresented: $showNewDestinationPrompt) {
            TextField("Destination name", text: $newDestinationName)
            Button("Create") { createDestinationHere() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a destination with this account and bucket, rooted at \(listPrefix.isEmpty ? "the bucket root" : "\u{201C}\(listPrefix)\u{201D}").")
        }
        .alert("Destination Created", isPresented: $didSaveDestination) {
            Button("OK") {}
        } message: {
            Text("\u{201C}\(newDestinationName)\u{201D} was added to your destinations.")
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: sortOverride) { _, _ in
            Task { await refresh() }
        }
        .sheet(item: $editingDestination, onDismiss: {
            // The editor may have changed the destination's default sort.
            if sortOverride == nil, loadedSort != sort {
                Task { await refresh() }
            }
        }) { dest in
            DestinationEditorView(destination: dest)
        }
        .sheet(item: $selectedObject) { object in
            ObjectDetailView(object: object, destination: destination) {
                objects.removeAll { $0.key == object.key }
            }
        }
        .sheet(item: $exportItem) { item in
            DocumentExporter(url: item.url)
        }
    }

    private func deleteMessage(for object: S3Object) -> String {
        let base = "This permanently deletes the file from \(destination.bucket)."
        return downloadStore.state(for: object, destination: destination) == .notDownloaded
            ? base
            : base + " Its downloaded copy on this device is removed too."
    }

    private var objectList: some View {
        List {
            if let parentPrefix {
                NavigationLink {
                    BucketBrowserView(destination: destination, prefix: parentPrefix, showsParentLink: true)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.turn.left.up")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        Text(parentName)
                            .lineLimit(1)
                        Spacer()
                        Text(parentPrefix.isEmpty ? "bucket root" : "parent folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            ForEach(folders) { folder in
                NavigationLink {
                    BucketBrowserView(destination: destination, prefix: folder.prefix)
                } label: {
                    FolderRow(folder: folder)
                }
            }

            ForEach(objects) { object in
                let state = downloadStore.state(for: object, destination: destination)
                Button {
                    selectedObject = object
                } label: {
                    ObjectRow(
                        object: object,
                        copied: copiedKey == object.key,
                        downloadState: state,
                        isDownloading: downloads.isActive(object)
                    )
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = object
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
                    switch state {
                    case .notDownloaded:
                        Button {
                            downloads.start(object: object, destination: destination)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .disabled(downloads.isActive(object))
                    case .outdated:
                        Button {
                            downloads.start(object: object, destination: destination)
                        } label: {
                            Label("Update Download", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(downloads.isActive(object))
                    case .downloaded:
                        EmptyView()
                    }
                    if state != .notDownloaded,
                       let local = downloadStore.localURL(for: object, destination: destination) {
                        Button {
                            exportItem = ExportItem(url: local)
                        } label: {
                            Label("Export…", systemImage: "square.and.arrow.up.on.square")
                        }
                        Button(role: .destructive) {
                            downloadStore.remove(for: object, destination: destination)
                        } label: {
                            Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        pendingDelete = object
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                // Attached to the row (not the List) so iOS anchors the
                // popover-style dialog to the file being deleted.
                .confirmationDialog(
                    "Delete \u{201C}\(object.filename)\u{201D}?",
                    isPresented: Binding(
                        get: { pendingDelete?.id == object.id },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        pendingDelete = nil
                        Task { await delete(object) }
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                } message: {
                    Text(deleteMessage(for: object))
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

    /// An existing destination already rooted at the folder being viewed
    /// (same account + bucket + prefix). When one exists the "…" menu offers
    /// its settings instead of creating a duplicate. Stored prefixes are
    /// normalized on save, so a direct compare against listPrefix works.
    private var destinationAtThisPrefix: Destination? {
        ConfigStore.shared.destinations.first {
            $0.accountId == destination.accountId
                && $0.bucket == destination.bucket
                && $0.pathPrefix == listPrefix
        }
    }

    /// Default name for a destination created from this folder: the folder's
    /// own name, falling back to the source destination's display title at
    /// the root.
    private var suggestedDestinationName: String {
        title
    }

    /// Saves a copy of this destination rooted at the folder being viewed.
    /// Same account, bucket and options — only the name and path change.
    private func createDestinationHere() {
        var copy = destination
        copy.id = UUID()
        copy.name = newDestinationName.trimmingCharacters(in: .whitespaces)
        copy.pathPrefix = listPrefix
        copy.sortOrder = 0  // upsert appends it after the existing ones
        ConfigStore.shared.upsertDestination(copy)
        didSaveDestination = true
    }

    private func refresh() async {
        guard let config else {
            errorMessage = "Destination not configured"
            return
        }
        let sort = self.sort
        isLoading = true
        defer { isLoading = false }
        do {
            if sort == .nameAscending {
                // S3 already lists names ascending, so page lazily.
                let page = try await S3Service.shared.listDirectory(
                    config: config, prefix: listPrefix, pageSize: Self.pageSize
                )
                folders = page.folders
                objects = page.objects
                nextToken = page.nextContinuationToken
            } else {
                // Other orders can't be paged from S3 — fetch the whole
                // level (bounded so a huge folder can't spin forever) and
                // sort client-side.
                var allFolders: [S3Folder] = []
                var allObjects: [S3Object] = []
                var token: String?
                for _ in 0..<25 {
                    let page = try await S3Service.shared.listDirectory(
                        config: config, prefix: listPrefix,
                        continuationToken: token, pageSize: Self.pageSize
                    )
                    allFolders.append(contentsOf: page.folders)
                    allObjects.append(contentsOf: page.objects)
                    token = page.nextContinuationToken
                    if token == nil { break }
                }
                (folders, objects) = Self.sorted(folders: allFolders, objects: allObjects, by: sort)
                nextToken = nil
            }
            loadedSort = sort
            errorMessage = nil
            isPermissionError = false
        } catch {
            errorMessage = error.localizedDescription
            isPermissionError = (error as? S3Service.S3Error)?.isPermissionIssue ?? false
        }
    }

    /// Applies the chosen order. Folders have no upload date, so recent-first
    /// keeps them in S3's name order.
    private static func sorted(
        folders: [S3Folder], objects: [S3Object], by sort: BrowserSort
    ) -> ([S3Folder], [S3Object]) {
        switch sort {
        case .nameAscending:
            (folders, objects)
        case .nameDescending:
            (
                folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending },
                objects.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
            )
        case .recentFirst:
            (folders, objects.sorted { $0.lastModified > $1.lastModified })
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
            DownloadStore.shared.remove(for: object, destination: destination)
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
    var downloadState: DownloadState = .notDownloaded
    var isDownloading: Bool = false

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
            } else if isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                switch downloadState {
                case .downloaded:
                    // White tick in a green bubble: available offline.
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                case .outdated:
                    // The remote file changed since it was downloaded.
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(.white, .orange)
                case .notDownloaded:
                    EmptyView()
                }
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
/// copy link / share / download / export / delete. Downloaded objects
/// preview from the local file (full quality, works offline) and open in
/// QuickLook for non-image types.
struct ObjectDetailView: View {
    let object: S3Object
    let destination: Destination
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var downloadStore = DownloadStore.shared
    @State private var downloads = DownloadManager.shared
    @State private var link: String?
    @State private var copied = false
    @State private var errorMessage: String?
    @State private var showQuickLook = false
    @State private var exportItem: ExportItem?
    @State private var confirmDelete = false

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"]
            .contains((object.key as NSString).pathExtension.lowercased())
    }

    private var downloadState: DownloadState {
        downloadStore.state(for: object, destination: destination)
    }

    private var localURL: URL? {
        downloadStore.localURL(for: object, destination: destination)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isImage, localURL != nil || link != nil {
                    RemoteImagePreview(
                        url: link.flatMap(URL.init(string:)),
                        localURL: localURL
                    )
                } else if let localURL {
                    // Downloaded non-image: tap to view offline in QuickLook.
                    Button {
                        showQuickLook = true
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.secondary)
                            Label("View File", systemImage: "eye")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.top, 24)
                    }
                    .buttonStyle(.plain)
                    .quickLookPreview(
                        Binding(
                            get: { showQuickLook ? localURL : nil },
                            set: { showQuickLook = $0 != nil }
                        )
                    )
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
                    if downloadState != .notDownloaded {
                        Label(
                            downloadState == .downloaded
                                ? "Available offline"
                                : "Downloaded copy is out of date",
                            systemImage: downloadState == .downloaded
                                ? "checkmark.circle.fill"
                                : "arrow.triangle.2.circlepath.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(downloadState == .downloaded ? .green : .orange)
                    }
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

                    // Share the actual file when a local copy exists,
                    // otherwise the link.
                    if let localURL {
                        ShareLink(item: localURL) {
                            Label("Share File", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else if let link, let url = URL(string: link) {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if downloads.isActive(object) {
                        Label("Downloading…", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else if downloadState != .downloaded {
                        Button {
                            downloads.start(object: object, destination: destination)
                        } label: {
                            Label(
                                downloadState == .outdated ? "Update Download" : "Download",
                                systemImage: downloadState == .outdated
                                    ? "arrow.triangle.2.circlepath"
                                    : "arrow.down.circle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let localURL {
                        Button {
                            exportItem = ExportItem(url: localURL)
                        } label: {
                            Label("Export…", systemImage: "square.and.arrow.up.on.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            downloadStore.remove(for: object, destination: destination)
                        } label: {
                            Label("Remove Download", systemImage: "arrow.down.circle.dotted")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    // On the button itself so the dialog anchors to it.
                    .confirmationDialog(
                        "Delete \u{201C}\(object.filename)\u{201D}?",
                        isPresented: $confirmDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) {
                            Task { await deleteObject() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(downloadState == .notDownloaded
                            ? "This permanently deletes the file from \(destination.bucket)."
                            : "This permanently deletes the file from \(destination.bucket). Its downloaded copy on this device is removed too.")
                    }
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
            .sheet(item: $exportItem) { item in
                DocumentExporter(url: item.url)
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
            DownloadStore.shared.remove(for: object, destination: destination)
            onDelete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Identifiable wrapper so a plain file URL can drive sheet(item:).
struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIDocumentPickerViewController in export-a-copy mode: lets the user copy
/// a downloaded file anywhere the Files app reaches (iCloud Drive, other
/// providers, On My iPhone).
struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

private struct RemoteImagePreview: View {
    /// Share link to fetch when there's no local copy.
    var url: URL? = nil
    /// Downloaded copy: preferred, full quality, no network needed.
    var localURL: URL? = nil

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
        .task(id: localURL ?? url) {
            didRequestPreview = false
            if !shouldWaitForTap {
                await load()
            }
        }
    }

    /// The cellular tap-gate only applies to remote fetches — a downloaded
    /// copy renders straight from disk.
    private var shouldWaitForTap: Bool {
        localURL == nil
            && config.requiresTapForCellularPreviews && network.isOnCellular && !didRequestPreview
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
            let data: Data
            if let localURL {
                data = try Data(contentsOf: localURL)
            } else if let url {
                let request = URLRequest(url: url)
                let (remoteData, response) = try await URLSession.shared.data(for: request)

                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    errorMessage = "The link returned HTTP \(http.statusCode). Copy the link to check whether the file still exists."
                    return
                }
                data = remoteData
            } else {
                errorMessage = "The image preview could not be loaded."
                return
            }

            // Downloaded copies always render at full quality — that's the
            // point of downloading; the bounded decode only applies to
            // remote previews.
            let uiImage = localURL != nil || config.rendersFullImagePreviews
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
