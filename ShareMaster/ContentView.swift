//
//  ContentView.swift
//  ShareMaster
//
//  Created by Conor Ryan on 02/07/26.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine
import AppKit
import Quartz
import ImageIO

// Model to track individual file upload state
struct UploadTask: Identifiable {
    let id = UUID()
    let filename: String
    let url: URL
    var progress: Double = 0
    var status: UploadStatus = .pending
    var resultURL: String?

    enum UploadStatus {
        case pending
        case uploading
        case completed
        case failed(String)
    }
}

/// A listed S3 object together with the destination it belongs to and its
/// resolved share link (public or presigned).
struct RecentItem: Identifiable {
    let object: S3Object
    let destination: Destination
    let link: String
    var id: UUID { object.id }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettingsAction) private var openSettings
    @Environment(\.openSettings) private var openNativeSettings

    var config = ConfigStore.shared

    @State private var selectedDestinationID: UUID?
    @State private var dropTargetID: UUID?
    @State private var isTargeted = false
    @State private var isUploading = false
    @State private var uploadTasks: [UploadTask] = []
    @State private var errorMessage: String?
    @State private var recentItems: [RecentItem] = []
    @State private var isLoadingList = false

    // Browser state (Browse mode) — folder navigation within the selected
    // destination. browsePrefix is the full key prefix currently shown.
    @State private var browsePrefix: String = ""
    @State private var browseFolders: [S3Folder] = []
    @State private var browseItems: [RecentItem] = []
    @State private var browseSortOverride: BrowserSort?
    @State private var newFolderName = ""
    @State private var showNewFolderPrompt = false
    @State private var newFolderError: String?
    // Browse-listing failure, shown inline in the section (not the top error
    // bar) so it can offer permission-specific guidance and a retry.
    @State private var browseError: String?
    @State private var browseErrorIsPermission = false

    // Download/Preview state
    @State private var downloadingObjectKey: String?
    @State private var downloadProgress: Double = 0

    /// Hidden destinations stay out of the popover (and Settings — the
    /// reveal flag lives on ConfigStore so both follow it) until the word
    /// mark in the header is clicked; resets each time the popover (re)opens.
    private var destinations: [Destination] {
        config.visibleDestinations
    }

    private var selectedDestination: Destination? {
        destinations.first { $0.id == selectedDestinationID } ?? destinations.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if destinations.isEmpty {
                notConfiguredView
            } else {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 168)
                    Divider()
                    detail
                }
            }
        }
        .frame(width: 560, height: config.recentsExpanded ? 460 : 212, alignment: .top)
        .task {
            // Popover content is rebuilt on each open, so this also picks up
            // config changes synced from other devices via iCloud Keychain.
            config.revealHidden = false
            config.refreshFromCloud()
            if selectedDestinationID == nil {
                let remembered = config.lastSelectedDestinationID
                selectedDestinationID = destinations.first { $0.id == remembered }?.id ?? destinations.first?.id
            }
            restoreBrowseLocation()
            await reloadExpanded()
        }
        .task {
            // The keychain posts no change notifications, so poll the cloud
            // payload while the popover is open to pick up edits made on
            // other devices. Cancelled when the popover closes. Cheap: one
            // keychain read; adoptCloudIfNewer bails on same version.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                config.refreshFromCloud()
            }
        }
        .onChange(of: config.recentsExpanded) { _, expanded in
            if expanded { Task { await reloadExpanded() } }
        }
        .onChange(of: config.browserPaneMode) { _, _ in
            Task { await reloadExpanded() }
        }
        .onChange(of: selectedDestinationID) { _, newValue in
            if let newValue { config.lastSelectedDestinationID = newValue }
            // A new destination has its own folder tree and default sort.
            browseSortOverride = nil
            restoreBrowseLocation()
            Task { await reloadExpanded() }
        }
        .onChange(of: browsePrefix) { _, newValue in
            if let id = selectedDestinationID { config.setBrowseLocation(newValue, for: id) }
        }
        .onChange(of: browseSortOverride) { _, _ in
            if config.recentsExpanded && config.browserPaneMode == .browse {
                Task { await loadBrowse() }
            }
        }
        .onChange(of: config.destinations) { _, _ in
            // Editing a destination (public URL base, link mode, expiry, bucket…)
            // invalidates the resolved links, so reload the visible section.
            if config.recentsExpanded { Task { await reloadExpanded() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .statusItemDidReceiveDrop)) { note in
            // Files dropped directly on the menu bar icon go to the current
            // destination, into the folder currently open in the browser.
            guard !isUploading,
                  let urls = note.userInfo?["urls"] as? [URL],
                  let destination = selectedDestination else { return }
            Task { @MainActor in
                await uploadFiles(urls, to: destination, keyPrefix: uploadKeyPrefix)
            }
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a folder in the current directory.")
        }
        .alert("Couldn't Create Folder", isPresented: Binding(
            get: { newFolderError != nil },
            set: { if !$0 { newFolderError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(newFolderError ?? "")
        }
    }

    /// The key prefix uploads and drops target: the folder currently open in
    /// Browse mode, or nil (the destination's configured root) in Recent (All).
    private var uploadKeyPrefix: String? {
        config.browserPaneMode == .browse ? browsePrefix : nil
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // The word mark doubles as the reveal switch for hidden
            // destinations; deliberately gives no visual hint.
            Text("ShareMaster")
                .font(.headline)
                .onTapGesture {
                    withAnimation { config.revealHidden.toggle() }
                }
            Spacer()
            HStack(spacing: 12) {
                Button {
                    openSettings()          // closes popover + activates app
                    openNativeSettings()    // opens the native Settings scene
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help("Settings")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit ShareMaster")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var notConfiguredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Destinations Yet")
                .font(.headline)
            Text("Add an account and a destination in settings to start uploading.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                openSettings()
                openNativeSettings()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollViewReader { proxy in
            sidebarList
                .onChange(of: dropTargetID) { _, targetID in
                    // While a drag hovers a row near the visible edge, nudge the
                    // list so its neighbours scroll into view — lets a drag walk
                    // up/down a destination list that doesn't fit the sidebar.
                    guard let targetID,
                          let index = destinations.firstIndex(where: { $0.id == targetID }) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if index + 1 < destinations.count {
                            proxy.scrollTo(destinations[index + 1].id)
                        }
                        if index > 0 {
                            proxy.scrollTo(destinations[index - 1].id)
                        }
                    }
                }
        }
    }

    private var sidebarList: some View {
        List(selection: $selectedDestinationID) {
            ForEach(destinations) { destination in
                DestinationRow(
                    destination: destination,
                    accountName: config.account(id: destination.accountId)?.name ?? "—",
                    isDropTarget: dropTargetID == destination.id
                )
                .tag(destination.id)
                .contextMenu {
                    // The editor doesn't fit inside the popover, so the draft
                    // is handed to the Settings window, which opens its
                    // Destinations editor pre-filled with it.
                    Button("Duplicate…") {
                        config.pendingDuplicate = config.duplicateDraft(of: destination)
                        openSettings()
                        openNativeSettings()
                    }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: Binding(
                    get: { dropTargetID == destination.id },
                    set: { targeted in
                        if targeted {
                            dropTargetID = destination.id
                        } else if dropTargetID == destination.id {
                            dropTargetID = nil
                        }
                    }
                )) { providers in
                    guard !isUploading else { return false }
                    NSApp.activate(ignoringOtherApps: true)
                    // Move focus to the destination that received the drop so the
                    // right side reflects where the files went.
                    selectedDestinationID = destination.id
                    handleDrop(providers, to: destination)
                    return true
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let destination = selectedDestination {
                DropZoneView(
                    isTargeted: $isTargeted,
                    isUploading: isUploading,
                    uploadTasks: uploadTasks
                )
                .onTapGesture {
                    if !isUploading { openFilePicker(destination, keyPrefix: uploadKeyPrefix) }
                }
                .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                    guard !isUploading else { return false }
                    NSApp.activate(ignoringOtherApps: true)
                    handleDrop(providers, to: destination, keyPrefix: uploadKeyPrefix)
                    return true
                }
                .padding(16)

                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                        Button {
                            errorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }

                expandableSection

                // Pin everything above to the top so collapsing/expanding the
                // section never shifts the header or drop zone.
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Expandable section (Browse / Recent All)

    private var isBrowse: Bool { config.browserPaneMode == .browse }

    private var expandableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
            if config.recentsExpanded {
                if isBrowse {
                    browserContent
                } else {
                    recentAllContent
                }
            }
        }
    }

    private var sectionTitle: String {
        if !isBrowse { return "Recent Uploads (All)" }
        guard let destination = selectedDestination else { return "Browse" }
        // At the destination's own root show its name; at the bucket root show
        // the bucket; anywhere else show the current folder's name.
        if browsePrefix == rootPrefix {
            return destination.name.isEmpty ? destination.bucket : destination.name
        }
        if browsePrefix.isEmpty { return destination.bucket }
        let trimmed = browsePrefix.hasSuffix("/") ? String(browsePrefix.dropLast()) : browsePrefix
        return (trimmed as NSString).lastPathComponent
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            // Collapsible: content only loads (and list requests only fire)
            // while this section is expanded.
            Button {
                config.recentsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(config.recentsExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: config.recentsExpanded)
                    Text(sectionTitle)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 4)

            if config.recentsExpanded {
                // Back one folder level (Browse mode, below the root only).
                if isBrowse && canGoBack {
                    Button {
                        browseBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Back")
                }

                sortMenu
                if isBrowse { browseActionsMenu }
                modeToggle

                if isLoadingList {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await reloadExpanded() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Browse ↔ Recent (All) switch.
    private var modeToggle: some View {
        Menu {
            Picker("View", selection: Binding(
                get: { config.browserPaneMode },
                set: { config.browserPaneMode = $0 }
            )) {
                Label("Browse Folders", systemImage: "folder").tag(BrowserPaneMode.browse)
                Label("Recent (All)", systemImage: "clock").tag(BrowserPaneMode.recentAll)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: isBrowse ? "folder" : "clock")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch between folder browsing and recent uploads")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: Binding(
                get: { browseSort },
                set: { browseSortOverride = $0 }
            )) {
                ForEach(BrowserSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
    }

    /// "…" menu: new folder here, plus the destination-here / settings actions.
    private var browseActionsMenu: some View {
        Menu {
            Button {
                newFolderName = ""
                showNewFolderPrompt = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Divider()
            if let existing = destinationAtCurrentPrefix {
                Button {
                    config.pendingDuplicate = existing   // opens editor pre-filled
                    openSettings()
                    openNativeSettings()
                } label: {
                    Label("View Destination Settings", systemImage: "slider.horizontal.3")
                }
            } else {
                Button {
                    createDestinationHere()
                } label: {
                    Label("New Destination Here", systemImage: "externaldrive.badge.plus")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Browse content

    @ViewBuilder
    private var browserContent: some View {
        // Shown whenever there's somewhere up to go (i.e. not at the bucket
        // root), so you can climb above the destination's own prefix too.
        if !browsePrefix.isEmpty {
            breadcrumbBar
        }
        if let browseError, browseFolders.isEmpty && browseItems.isEmpty {
            browseErrorView(browseError)
        } else if browseFolders.isEmpty && browseItems.isEmpty && !isLoadingList {
            VStack {
                Text(browsePrefix == rootPrefix ? "No files yet" : "Empty folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(browseFolders) { folder in
                    MacFolderRow(name: folderDisplayName(folder))
                        .contentShape(Rectangle())
                        .onTapGesture { drillInto(folder) }
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                }
                ForEach(browseItems) { item in
                    fileRow(for: item, badge: nil)
                        .id(item.object.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.never)
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(breadcrumbs) { crumb in
                    Button {
                        if crumb.prefix != browsePrefix { browsePrefix = crumb.prefix; Task { await loadBrowse() } }
                    } label: {
                        Text(crumb.label)
                            .font(.caption)
                            .foregroundStyle(crumb.prefix == browsePrefix ? Color.primary : Color.accentColor)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    if crumb.prefix != breadcrumbs.last?.prefix {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    /// Inline listing-failure state. A permission denial gets specific guidance
    /// (likely when browsing above the destination's own prefix); anything else
    /// shows the underlying message. Both offer a retry.
    private func browseErrorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: browseErrorIsPermission ? "lock.fill" : "exclamationmark.icloud")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(browseErrorIsPermission ? "Can't list this location" : "Couldn't load")
                .font(.subheadline.weight(.medium))
            Text(browseErrorIsPermission
                 ? "This account isn't allowed to list here. Check its credentials and that its IAM or bucket policy grants s3:ListBucket for this path."
                 : message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            HStack(spacing: 8) {
                if canGoBack {
                    Button("Go Up") { browseBack() }
                        .buttonStyle(.borderless)
                }
                Button("Retry") { Task { await loadBrowse() } }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Recent (All) content

    @ViewBuilder
    private var recentAllContent: some View {
        if recentItems.isEmpty && !isLoadingList {
            VStack {
                Text("No files yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(recentItems) { item in
                        fileRow(for: item, badge: item.destination.name)
                            .id(item.object.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    }
                }
                .listStyle(.plain)
                .scrollIndicators(.never)
                .onChange(of: recentItems.first?.id) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
            }
        }
    }

    private func fileRow(for item: RecentItem, badge: String?) -> some View {
        FileRowView(
            object: item.object,
            previewURL: previewURL(for: item),
            badge: badge,
            isDownloading: downloadingObjectKey == item.object.key,
            downloadProgress: downloadingObjectKey == item.object.key ? downloadProgress : 0
        ) {
            copyToClipboard(item)
        } onDelete: {
            await deleteObject(item)
        } onDownload: { choosePanel in
            await downloadToDownloads(item, forcePanel: choosePanel)
        } onPreview: {
            previewFile(item)
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider], to destination: Destination, keyPrefix: String? = nil) {
        let lock = NSLock()
        var collectedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            Self.resolveDroppedFileURL(from: provider) { url in
                defer { group.leave() }
                guard let url else { return }
                lock.lock()
                collectedURLs.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            Task { @MainActor in
                guard !collectedURLs.isEmpty else {
                    self.errorMessage = "No files found in drop."
                    return
                }
                await self.uploadFiles(collectedURLs, to: destination, keyPrefix: keyPrefix)
            }
        }
    }

    private static func resolveDroppedFileURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let url = Self.fileURL(from: item) {
                completion(url)
                return
            }
            Self.loadPromisedFile(from: provider, completion: completion)
        }
    }

    private static func loadPromisedFile(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        var candidateTypes = [UTType.fileURL.identifier]
        for identifier in provider.registeredTypeIdentifiers where !candidateTypes.contains(identifier) {
            candidateTypes.append(identifier)
        }

        func attempt(_ index: Int) {
            guard index < candidateTypes.count else {
                completion(nil)
                return
            }

            let typeIdentifier = candidateTypes[index]
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url,
                      let stableURL = Self.copyPromisedDrop(url, typeIdentifier: typeIdentifier, suggestedName: provider.suggestedName) else {
                    attempt(index + 1)
                    return
                }
                completion(stableURL)
            }
        }

        attempt(0)
    }

    private static func copyPromisedDrop(_ url: URL, typeIdentifier: String, suggestedName: String?) -> URL? {
        let fileManager = FileManager.default
        let dropDirectory = fileManager.temporaryDirectory.appendingPathComponent("ShareMasterDrops", isDirectory: true)
        try? fileManager.createDirectory(at: dropDirectory, withIntermediateDirectories: true)

        let sourceExtension = url.pathExtension
        let typeExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? ""
        let fallbackExtension = sourceExtension.isEmpty ? typeExtension : sourceExtension
        var filename = suggestedName?.isEmpty == false ? suggestedName! : url.lastPathComponent
        filename = (filename as NSString).lastPathComponent
        if (filename as NSString).pathExtension.isEmpty && !fallbackExtension.isEmpty {
            filename += ".\(fallbackExtension)"
        }

        let destination = dropDirectory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        do {
            try fileManager.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        switch item {
        case let url as URL:
            return url.isFileURL ? url : nil
        case let url as NSURL:
            let bridged = url as URL
            return bridged.isFileURL ? bridged : nil
        case let data as Data:
            let url = URL(dataRepresentation: data, relativeTo: nil)
            return url?.isFileURL == true ? url : nil
        case let string as String:
            let url = URL(string: string)
            return url?.isFileURL == true ? url : nil
        default:
            return nil
        }
    }

    private func openFilePicker(_ destination: Destination, keyPrefix: String? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK else { return }
                Task { @MainActor in
                    await uploadFiles(panel.urls, to: destination, keyPrefix: keyPrefix)
                }
            }
        } else {
            let response = panel.runModal()
            guard response == .OK else { return }
            Task { @MainActor in
                await uploadFiles(panel.urls, to: destination, keyPrefix: keyPrefix)
            }
        }
    }

    @MainActor
    private func uploadFiles(_ urls: [URL], to destination: Destination, keyPrefix: String? = nil) async {
        guard !urls.isEmpty else { return }
        guard let cfg = config.s3Config(for: destination) else {
            errorMessage = "This destination has no valid account."
            return
        }

        uploadTasks = urls.map { UploadTask(filename: $0.lastPathComponent, url: $0) }
        isUploading = true
        errorMessage = nil

        var uploadedURLs: [String] = []

        for index in uploadTasks.indices {
            uploadTasks[index].status = .uploading

            do {
                let fileURL = uploadTasks[index].url
                let didAccessFile = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccessFile {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }

                let result = try await S3Service.shared.upload(fileURL: fileURL, config: cfg, keyPrefix: keyPrefix) { progress in
                    Task { @MainActor in
                        if index < self.uploadTasks.count {
                            self.uploadTasks[index].progress = progress
                        }
                    }
                }

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
                let uploadedFile = UploadedFile(
                    filename: fileURL.lastPathComponent,
                    key: result.key,
                    url: result.url,
                    size: fileSize
                )
                modelContext.insert(uploadedFile)

                uploadTasks[index].status = .completed
                uploadTasks[index].progress = 1
                uploadTasks[index].resultURL = result.url
                uploadedURLs.append(result.url)

                // Optimistically add to the visible list. Skip while collapsed
                // — the list reloads fresh on next expand.
                if config.recentsExpanded {
                    let newObject = S3Object(key: result.key, size: fileSize, lastModified: Date())
                    let item = RecentItem(object: newObject, destination: destination, link: result.url)
                    if isBrowse {
                        // Only when it landed in the folder currently shown for
                        // the selected destination.
                        if destination.id == selectedDestination?.id, (keyPrefix ?? cfg.pathPrefix) == browsePrefix {
                            browseItems.insert(item, at: 0)
                        }
                    } else {
                        recentItems.insert(item, at: 0)
                        if recentItems.count > config.recentLimit {
                            recentItems.removeLast(recentItems.count - config.recentLimit)
                        }
                    }
                }

            } catch {
                uploadTasks[index].status = .failed(error.localizedDescription)
                errorMessage = "Some uploads failed"
            }
        }

        // Copy links to clipboard only if the destination opts in.
        if destination.copyOnUpload && !uploadedURLs.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(uploadedURLs.joined(separator: "\n"), forType: .string)
        }

        let allSucceeded = uploadTasks.allSatisfy {
            if case .completed = $0.status { return true }
            return false
        }

        try? await Task.sleep(for: .seconds(2))
        uploadTasks = []
        isUploading = false

        NotificationCenter.default.post(
            name: .uploadDidFinish,
            object: nil,
            userInfo: ["success": allSucceeded]
        )
    }

    // MARK: - Loading

    /// Loads whichever mode is showing, if the section is expanded.
    private func reloadExpanded() async {
        guard config.recentsExpanded else { return }
        if isBrowse {
            await loadBrowse()
        } else {
            await loadRecentAll()
        }
    }

    /// Recent (All): newest-first, merged across every visible destination.
    private func loadRecentAll() async {
        guard !destinations.isEmpty else { recentItems = []; return }
        isLoadingList = true
        defer { isLoadingList = false }

        let targets = destinations.compactMap { dest -> (Destination, S3Config)? in
            guard let cfg = config.s3Config(for: dest) else { return nil }
            return (dest, cfg)
        }
        var merged: [RecentItem] = []
        await withTaskGroup(of: [RecentItem].self) { group in
            for (dest, cfg) in targets {
                group.addTask { [limit = config.recentLimit] in
                    guard let objects = try? await S3Service.shared.listObjects(config: cfg) else { return [] }
                    let limited = Array(objects.prefix(limit))
                    return await self.resolveItems(limited, destination: dest, config: cfg)
                }
            }
            for await items in group { merged.append(contentsOf: items) }
        }
        recentItems = Array(
            merged.sorted { $0.object.lastModified > $1.object.lastModified }
                .prefix(config.recentLimit)
        )
    }

    // MARK: - Browse

    /// The selected destination's configured root prefix — the top of the
    /// browse tree. Back-navigation never climbs above this.
    private var rootPrefix: String {
        config.s3Config(for: selectedDestination ?? destinations.first ?? Destination(accountId: UUID()))?.pathPrefix ?? ""
    }

    /// Effective sort: the per-view override, else the destination's default.
    private var browseSort: BrowserSort {
        browseSortOverride ?? selectedDestination?.defaultBrowserSort ?? .recentFirst
    }

    /// Can climb until the bucket root (""), passing through — and above — the
    /// destination's configured prefix, exactly like the iOS up row.
    private var canGoBack: Bool {
        !browsePrefix.isEmpty
    }

    /// Restores the last-viewed folder for the selected destination. Any prefix
    /// under the same bucket is valid for the account's credentials, so it's
    /// restored as-is; falls back to the destination root when nothing's saved.
    private func restoreBrowseLocation() {
        if let id = selectedDestinationID, let saved = config.browseLocation(for: id) {
            browsePrefix = saved
        } else {
            browsePrefix = rootPrefix
        }
    }

    private func folderDisplayName(_ folder: S3Folder) -> String {
        let trimmed = folder.prefix.hasSuffix("/") ? String(folder.prefix.dropLast()) : folder.prefix
        return (trimmed as NSString).lastPathComponent
    }

    private func drillInto(_ folder: S3Folder) {
        browsePrefix = folder.prefix
        Task { await loadBrowse() }
    }

    private func browseBack() {
        guard canGoBack else { return }
        let trimmed = browsePrefix.hasSuffix("/") ? String(browsePrefix.dropLast()) : browsePrefix
        var parent = (trimmed as NSString).deletingLastPathComponent
        if !parent.isEmpty { parent += "/" }
        browsePrefix = parent   // "" == bucket root
        Task { await loadBrowse() }
    }

    struct Breadcrumb: Identifiable {
        let label: String
        let prefix: String
        var id: String { prefix }
    }

    /// Full path from the bucket root: bucket crumb, then one per folder level.
    /// Jumping to any crumb (including above the destination's own prefix) is
    /// allowed — the account's credentials cover the whole bucket.
    private var breadcrumbs: [Breadcrumb] {
        let bucketLabel = selectedDestination?.bucket ?? "Bucket"
        var crumbs = [Breadcrumb(label: bucketLabel, prefix: "")]
        let parts = browsePrefix.split(separator: "/", omittingEmptySubsequences: true)
        var acc = ""
        for part in parts {
            acc += part + "/"
            crumbs.append(Breadcrumb(label: String(part), prefix: acc))
        }
        return crumbs
    }

    private func loadBrowse() async {
        guard let destination = selectedDestination,
              let cfg = config.s3Config(for: destination) else {
            browseFolders = []; browseItems = []; return
        }
        isLoadingList = true
        defer { isLoadingList = false }
        let sort = browseSort
        do {
            // Fetch the level (bounded so a huge folder can't spin forever),
            // then order client-side. Folder markers are hidden by the service.
            var allFolders: [S3Folder] = []
            var allObjects: [S3Object] = []
            var token: String?
            for _ in 0..<25 {
                let page = try await S3Service.shared.listDirectory(
                    config: cfg, prefix: browsePrefix,
                    continuationToken: token, pageSize: 100
                )
                allFolders.append(contentsOf: page.folders)
                allObjects.append(contentsOf: page.objects)
                token = page.nextContinuationToken
                if token == nil { break }
            }
            let (folders, objects) = Self.sortedBrowse(folders: allFolders, objects: allObjects, by: sort)
            browseFolders = folders
            browseItems = await resolveItems(objects, destination: destination, config: cfg)
            browseError = nil
            browseErrorIsPermission = false
        } catch {
            // Surface listing failures inside the section (with permission
            // guidance) rather than the top bar — browsing arbitrary bucket
            // levels can legitimately hit ListBucket denials.
            browseErrorIsPermission = (error as? S3Service.S3Error)?.isPermissionIssue ?? false
            browseError = error.localizedDescription
            browseFolders = []; browseItems = []
        }
    }

    private static func sortedBrowse(
        folders: [S3Folder], objects: [S3Object], by sort: BrowserSort
    ) -> ([S3Folder], [S3Object]) {
        switch sort {
        case .nameAscending:
            return (folders, objects)   // S3 already lists ascending
        case .nameDescending:
            return (
                folders.sorted { folderName($0).localizedStandardCompare(folderName($1)) == .orderedDescending },
                objects.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }
            )
        case .recentFirst:
            // Folders carry no date, so leave them in name order at the top.
            return (folders, objects.sorted { $0.lastModified > $1.lastModified })
        }
    }

    private static func folderName(_ folder: S3Folder) -> String {
        let trimmed = folder.prefix.hasSuffix("/") ? String(folder.prefix.dropLast()) : folder.prefix
        return (trimmed as NSString).lastPathComponent
    }

    // MARK: - Folder / destination actions

    /// An existing destination already rooted at the folder being browsed
    /// (same account + bucket + prefix), so we offer its settings rather than
    /// a duplicate.
    private var destinationAtCurrentPrefix: Destination? {
        guard let destination = selectedDestination else { return nil }
        return config.destinations.first {
            $0.accountId == destination.accountId
                && $0.bucket == destination.bucket
                && $0.pathPrefix == browsePrefix
        }
    }

    private func createFolder() {
        guard let destination = selectedDestination,
              let cfg = config.s3Config(for: destination) else { return }
        let name = newFolderName
        Task {
            do {
                try await S3Service.shared.createFolder(named: name, under: browsePrefix, config: cfg)
                await loadBrowse()
            } catch {
                newFolderError = error.localizedDescription
            }
        }
    }

    /// Saves a copy of the selected destination rooted at the current folder —
    /// same account, bucket and options, only the name and path change.
    private func createDestinationHere() {
        guard let destination = selectedDestination else { return }
        var copy = destination
        copy.id = UUID()
        let baseName = folderDisplayName(S3Folder(prefix: browsePrefix)).isEmpty
            ? destination.name
            : folderDisplayName(S3Folder(prefix: browsePrefix))
        let names = config.destinations.map(\.name)
        copy.name = names.contains(baseName) ? ConfigStore.copyName(baseName, existing: names) : baseName
        copy.pathPrefix = browsePrefix
        copy.sortOrder = 0
        config.upsertDestination(copy)
    }

    /// Resolves a share link for each object so copy/preview are instant.
    private func resolveItems(_ objects: [S3Object], destination: Destination, config cfg: S3Config) async -> [RecentItem] {
        var items: [RecentItem] = []
        for object in objects {
            let link = (try? await S3Service.shared.shareLink(for: object.key, config: cfg)) ?? ""
            items.append(RecentItem(object: object, destination: destination, link: link))
        }
        return items
    }

    // MARK: - Actions

    private func copyToClipboard(_ item: RecentItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.link, forType: .string)
    }

    private func previewURL(for item: RecentItem) -> URL? {
        guard isImageFile(item.object.filename), !item.link.isEmpty else { return nil }
        return URL(string: item.link)
    }

    private func isImageFile(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "svg"].contains(ext)
    }

    private func deleteObject(_ item: RecentItem) async {
        guard let cfg = config.s3Config(for: item.destination) else { return }
        do {
            try await S3Service.shared.deleteObject(key: item.object.key, config: cfg)
            recentItems.removeAll { $0.object.id == item.object.id }
            browseItems.removeAll { $0.object.id == item.object.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Cache

    private func cachedFileURL(for object: S3Object) -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ShareMaster")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir.appendingPathComponent((object.key as NSString).lastPathComponent)
    }

    private func getCachedFile(for object: S3Object) -> URL? {
        let cachedURL = cachedFileURL(for: object)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        return nil
    }

    // MARK: - Download

    /// Saves into the destination's download folder (custom folder or
    /// ~/Downloads). "Choose every time" destinations — and any option-click
    /// on the download button — show a save panel instead.
    private func downloadToDownloads(_ item: RecentItem, forcePanel: Bool = false) async {
        guard let cfg = config.s3Config(for: item.destination) else { return }
        let object = item.object

        let target: URL
        var scopedFolder: URL?

        if forcePanel || item.destination.effectiveDownloadLocation == .ask {
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = object.filename
            savePanel.canCreateDirectories = true
            savePanel.isExtensionHidden = false
            NSApp.activate(ignoringOtherApps: true)
            guard await savePanel.begin() == .OK, let chosen = savePanel.url else { return }
            // Panel already confirmed replacement, so clear the way.
            try? FileManager.default.removeItem(at: chosen)
            target = chosen
        } else {
            let (folder, isScoped) = ConfigStore.downloadDirectory(for: item.destination)
            if isScoped, folder.startAccessingSecurityScopedResource() {
                scopedFolder = folder
            }
            target = uniqueTarget(in: folder, filename: object.filename)
        }
        defer { scopedFolder?.stopAccessingSecurityScopedResource() }

        if let cachedURL = getCachedFile(for: object) {
            do {
                try FileManager.default.copyItem(at: cachedURL, to: target)
                NSWorkspace.shared.selectFile(target.path, inFileViewerRootedAtPath: "")
                return
            } catch {
                // Cache copy failed, fall through to download
            }
        }

        do {
            downloadingObjectKey = object.key
            downloadProgress = 0

            let cacheURL = cachedFileURL(for: object)
            let savedURL = try await S3Service.shared.download(key: object.key, to: cacheURL, config: cfg, overwrite: true) { progress in
                Task { @MainActor in
                    downloadProgress = progress
                }
            }

            try FileManager.default.copyItem(at: savedURL, to: target)
            downloadingObjectKey = nil
            NSWorkspace.shared.selectFile(target.path, inFileViewerRootedAtPath: "")
        } catch {
            downloadingObjectKey = nil
            errorMessage = error.localizedDescription
        }
    }

    /// "photo.png" → "photo (1).png" etc. until the name is free.
    private func uniqueTarget(in folder: URL, filename: String) -> URL {
        let fileManager = FileManager.default
        var target = folder.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: target.path) else { return target }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1
        repeat {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            target = folder.appendingPathComponent(name)
            counter += 1
        } while fileManager.fileExists(atPath: target.path)
        return target
    }

    // MARK: - Preview with Quick Look

    private func previewFile(_ item: RecentItem) {
        guard let cfg = config.s3Config(for: item.destination) else { return }
        let object = item.object
        Task {
            let tempFile = cachedFileURL(for: object)

            if let cachedURL = getCachedFile(for: object) {
                await MainActor.run { showQuickLook(for: cachedURL) }
                return
            }

            do {
                downloadingObjectKey = object.key
                downloadProgress = 0

                let savedURL = try await S3Service.shared.download(key: object.key, to: tempFile, config: cfg, overwrite: true) { progress in
                    Task { @MainActor in
                        downloadProgress = progress
                    }
                }

                downloadingObjectKey = nil
                await MainActor.run { showQuickLook(for: savedURL) }
            } catch {
                downloadingObjectKey = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func showQuickLook(for url: URL) {
        let coordinator = QuickLookCoordinator()
        coordinator.items = [QuickLookItem(url: url)]
        Self.quickLookCoordinator = coordinator

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = coordinator
        panel.delegate = coordinator
        panel.currentPreviewItemIndex = 0

        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private static var quickLookCoordinator: QuickLookCoordinator?
}

// MARK: - Destination sidebar row

struct DestinationRow: View {
    let destination: Destination
    let accountName: String
    var isDropTarget: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(destination.name.isEmpty ? "Untitled" : destination.name)
                .font(.system(.subheadline).weight(.medium))
                .foregroundStyle(isDropTarget ? .white : .primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(isDropTarget ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Mimics the sidebar selection pill while a drag hovers over the row.
            RoundedRectangle(cornerRadius: 5)
                .fill(isDropTarget ? Color.accentColor : Color.clear)
                .padding(.horizontal, -7)
                .padding(.vertical, -3)
        )
        .animation(.easeInOut(duration: 0.1), value: isDropTarget)
    }

    private var subtitle: String {
        let path = destination.pathPrefix.isEmpty ? "" : "/\(destination.pathPrefix)"
        return "\(destination.bucket)\(path)"
    }
}

// MARK: - Browser folder row

struct MacFolderRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)

            Text(name)
                .font(.system(.subheadline).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }
}

struct DropZoneView: View {
    @Binding var isTargeted: Bool
    let isUploading: Bool
    let uploadTasks: [UploadTask]

    private var completedCount: Int {
        uploadTasks.filter {
            if case .completed = $0.status { return true }
            return false
        }.count
    }

    private var totalCount: Int {
        uploadTasks.count
    }

    private var overallProgress: Double {
        guard !uploadTasks.isEmpty else { return 0 }
        return uploadTasks.reduce(0) { $0 + $1.progress } / Double(uploadTasks.count)
    }

    private var currentlyUploading: UploadTask? {
        uploadTasks.first {
            if case .uploading = $0.status { return true }
            return false
        }
    }

    private var allCompleted: Bool {
        completedCount == totalCount && totalCount > 0
    }

    var body: some View {
        VStack(spacing: 8) {
            if isUploading {
                if allCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                    if totalCount == 1 {
                        Text("Uploaded!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(totalCount) files uploaded!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 6) {
                        ProgressView(value: overallProgress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 220)

                        if totalCount == 1 {
                            Text("Uploading \(currentlyUploading?.filename ?? "")...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("Uploading \(completedCount + 1) of \(totalCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let current = currentlyUploading {
                                Text(current.filename)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.up.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text(isTargeted ? "Drop to upload" : "Drop files here or click to select")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isTargeted ? 2 : 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}

// Custom progress style that doesn't gray out when window loses focus
struct ActiveProgressViewStyle: ProgressViewStyle {
    var height: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            let progress = configuration.fractionCompleted ?? 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * progress)
                    .animation(.easeOut(duration: 0.15), value: progress)
            }
        }
        .frame(height: height)
    }
}

enum CachedImageState {
    case loading
    case success(Image)
    case failure
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 300
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

final class ImageLoader: ObservableObject {
    @Published var state: CachedImageState = .loading
    private var task: Task<Void, Never>?

    func load(from url: URL) {
        if let cached = ImageCache.shared.image(for: url) {
            state = .success(Image(nsImage: cached))
            return
        }

        task?.cancel()
        task = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                // Decode straight to a small thumbnail — a 12 MP photo decodes
                // to ~48 MB of bitmap, all to draw a 32 pt row icon.
                guard let image = Self.downsampledImage(from: data, maxPixel: 96) else {
                    await MainActor.run { self.state = .failure }
                    return
                }
                ImageCache.shared.insert(image, for: url)
                await MainActor.run { self.state = .success(Image(nsImage: image)) }
            } catch {
                await MainActor.run { self.state = .failure }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    nonisolated private static func downsampledImage(from data: Data, maxPixel: CGFloat) -> NSImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return NSImage(data: data)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct CachedAsyncImage<Content: View>: View {
    let url: URL
    @ViewBuilder let content: (CachedImageState) -> Content
    @StateObject private var loader = ImageLoader()

    var body: some View {
        content(loader.state)
            .onAppear { loader.load(from: url) }
            .onChange(of: url) { _, newURL in
                loader.load(from: newURL)
            }
            .onDisappear { loader.cancel() }
    }
}

struct FileRowView: View {
    let object: S3Object
    let previewURL: URL?
    var badge: String? = nil
    let isDownloading: Bool
    let downloadProgress: Double
    let onCopy: () -> Void
    let onDelete: () async -> Void
    /// The Bool is true when the user option-clicked (choose location).
    let onDownload: (Bool) async -> Void
    let onPreview: () -> Void

    @State private var isHovered = false
    @State private var isDeleting = false
    @State private var isCopied = false

    var body: some View {
        HStack(spacing: 10) {
            if let previewURL {
                CachedAsyncImage(url: previewURL) { state in
                    switch state {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    case .loading:
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    Image(systemName: iconForFile(object.filename))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(object.filename)
                    .font(.system(.subheadline).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isDownloading {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(ActiveProgressViewStyle(height: 6))
                        .padding(.top, 2)
                } else {
                    HStack(spacing: 6) {
                        if let badge {
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(formatSize(object.size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    if !isDeleting && !isDownloading {
                        onCopy()
                        Task { @MainActor in
                            withAnimation(.easeInOut(duration: 0.15)) { isCopied = true }
                            try? await Task.sleep(for: .seconds(1))
                            withAnimation(.easeInOut(duration: 0.15)) { isCopied = false }
                        }
                    }
                } label: {
                    Image(systemName: isCopied ? "checkmark.circle.fill" : "link")
                        .foregroundStyle(isCopied ? Color.green : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy link")
                .disabled(isDeleting || isDownloading)

                Button {
                    let choosePanel = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
                    Task { await onDownload(choosePanel) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Download (⌥-click to choose location)")
                .disabled(isDeleting || isDownloading)

                Button {
                    Task {
                        isDeleting = true
                        await onDelete()
                        isDeleting = false
                    }
                } label: {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                }
                .buttonStyle(.borderless)
                .help("Delete")
                .disabled(isDeleting || isDownloading)
            }
            .opacity(isHovered || isDeleting || isDownloading ? 1 : 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if !isDownloading { onPreview() }
        }
    }

    private func iconForFile(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "svg":
            return "photo"
        case "mp4", "mov", "avi":
            return "video"
        case "mp3", "wav", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "rar", "7z":
            return "archivebox"
        default:
            return "doc"
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Quick Look Support

class QuickLookItem: NSObject, QLPreviewItem {
    let url: URL

    init(url: URL) {
        self.url = url
        super.init()
    }

    var previewItemURL: URL? { url }
    var previewItemTitle: String? { url.lastPathComponent }
}

class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [QuickLookItem] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index < items.count else { return nil }
        return items[index]
    }
}

#Preview {
    ContentView()
        .modelContainer(for: UploadedFile.self, inMemory: true)
}
