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

    // Redesign UI state: which row is selected (drives the blue highlight and
    // the inline action buttons) and whether the Destinations sidebar is
    // collapsed to reclaim width for the file table.
    @State private var selectedItemID: UUID?
    @State private var sidebarCollapsed = false

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
                breadcrumbHeaderBar
                Divider()
                HStack(spacing: 0) {
                    if sidebarCollapsed {
                        collapsedRail
                            .frame(width: 46)
                    } else {
                        sidebar
                            .frame(width: 190)
                    }
                    Divider()
                    detail
                }
            }
        }
        .frame(width: 780, height: 580, alignment: .top)
        .task {
            // Popover content is rebuilt on each open, so this also picks up
            // config changes synced from other devices via iCloud Keychain.
            config.revealHidden = false
            // The redesign always shows the file table (no collapsed state), so
            // keep the loading gate open.
            config.recentsExpanded = true
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
            // Switching Browse ↔ Recent shows a different listing — clear and
            // spin rather than flashing the previous mode's rows.
            browseFolders = []
            browseItems = []
            recentItems = []
            isLoadingList = true
            Task { await reloadExpanded() }
        }
        .onChange(of: selectedDestinationID) { _, newValue in
            // Just remember the focus. Navigation to the destination's root is
            // driven explicitly by selectDestination(_:); on popover open the
            // last-viewed folder is restored by the .task above.
            if let newValue { config.lastSelectedDestinationID = newValue }
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
        HStack(spacing: 10) {
            ShareMasterLogo()
                .frame(width: 34, height: 34)
            // The word mark doubles as the reveal switch for hidden
            // destinations; deliberately gives no visual hint.
            Text("ShareMaster")
                .font(.title3.weight(.semibold))
                .onTapGesture {
                    withAnimation { config.revealHidden.toggle() }
                }

            Spacer()

            HStack(spacing: 8) {
                HeaderIconButton(systemName: "folder.badge.plus", help: "New folder") {
                    newFolderName = ""
                    showNewFolderPrompt = true
                }
                .disabled(!isBrowse || selectedDestination == nil)

                HeaderIconButton(
                    systemName: "arrow.clockwise",
                    help: "Refresh",
                    isBusy: isLoadingList
                ) {
                    Task { await reloadExpanded() }
                }

                HeaderIconButton(systemName: "gearshape", help: "Settings") {
                    openSettings()          // closes popover + activates app
                    openNativeSettings()    // opens the native Settings scene
                }

                HeaderIconButton(systemName: "power", help: "Quit ShareMaster") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Breadcrumb bar

    /// Full-width path bar under the header. A home button jumps to the bucket
    /// root; the remaining crumbs are the folders below it. In Recent (All) mode
    /// there's no path, so it shows a static label instead.
    private var breadcrumbHeaderBar: some View {
        let crumbs = isBrowse ? breadcrumbs : []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Button {
                    navigate(to: crumbs.first?.prefix ?? "")
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Bucket root")

                if isBrowse {
                    ForEach(crumbs.dropFirst()) { crumb in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Button {
                            navigate(to: crumb.prefix)
                        } label: {
                            Text(crumb.label)
                                .font(.system(size: 13, weight: crumb.prefix == browsePrefix ? .semibold : .regular))
                                .foregroundStyle(crumb.prefix == browsePrefix ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("Recent Uploads")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Navigates the browser to an absolute key prefix (used by breadcrumbs).
    private func navigate(to prefix: String) {
        guard isBrowse, prefix != browsePrefix else { return }
        navigateBrowse(to: prefix)
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
        VStack(alignment: .leading, spacing: 0) {
            Text("Destinations")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(destinations) { destination in
                            destinationRow(destination)
                                .id(destination.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
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

            Spacer(minLength: 0)

            Divider()
            HStack {
                Button { addDestinationFromCurrentView() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(addButtonHelp)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed = true }
                } label: {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide destinations")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    /// The thin rail shown when the sidebar is collapsed: the file table shifts
    /// right of it, and the add / expand controls stay pinned to the bottom in
    /// the same spot as the expanded footer (rather than jumping to the header).
    private var collapsedRail: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Divider()
            VStack(spacing: 12) {
                Button { addDestinationFromCurrentView() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(addButtonHelp)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed = false }
                } label: {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show destinations")
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    private func destinationRow(_ destination: Destination) -> some View {
        let isSelected = selectedDestinationID == destination.id
        let isDrop = dropTargetID == destination.id
        return DestinationRow(destination: destination, isSelected: isSelected, isDropTarget: isDrop)
            .contentShape(Rectangle())
            .onTapGesture { selectDestination(destination) }
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
                // Move focus to the destination that received the drop (and reset
                // it to its root) so the right side reflects where the files went.
                selectDestination(destination)
                handleDrop(providers, to: destination)
                return true
            }
    }

    /// Focuses a destination and always returns it to its configured root —
    /// tapping a destination icon (even the current one) resets the browser to
    /// the "stated" destination rather than a previously-visited subfolder.
    /// Navigation the user does afterwards persists until the next such tap.
    private func selectDestination(_ destination: Destination) {
        selectedDestinationID = destination.id
        browseSortOverride = nil
        // Clear the previous destination's contents and show the spinner right
        // away rather than lingering on them while the new listing loads.
        browseFolders = []
        browseItems = []
        recentItems = []
        browseError = nil
        isLoadingList = true
        let root = rootPrefix(for: destination)
        browsePrefix = root
        config.setBrowseLocation(root, for: destination.id)
        Task { await reloadExpanded() }
    }

    private func rootPrefix(for destination: Destination) -> String {
        config.s3Config(for: destination)?.pathPrefix ?? ""
    }

    /// Opens Settings on the Add-Destination flow. Hands a blank draft to the
    /// Settings window (via the same pending-draft channel used by Duplicate)
    /// so its Destinations editor opens ready to fill in.
    /// The sidebar "+" button. When browsing inside a folder that isn't already
    /// a destination, it clones the current destination rooted there (prefilled
    /// name, same account/bucket/options, rewritten public URL). Otherwise —
    /// on Recents, or when the current folder is already a destination — it
    /// falls back to opening a blank destination editor.
    private var addButtonHelp: String {
        if isBrowse, selectedDestination != nil, destinationAtCurrentPrefix == nil {
            let name = folderDisplayName(S3Folder(prefix: browsePrefix))
            return name.isEmpty ? "Save this folder as a destination" : "Save “\(name)” as a destination"
        }
        return "Add destination"
    }

    private func addDestinationFromCurrentView() {
        if isBrowse, selectedDestination != nil, destinationAtCurrentPrefix == nil {
            createDestinationHere()
        } else {
            addDestination()
        }
    }

    private func addDestination() {
        if let account = config.visibleAccounts.first {
            config.pendingDuplicate = Destination(accountId: account.id)
        }
        openSettings()
        openNativeSettings()
    }

    // MARK: - Detail (file table)

    private var isBrowse: Bool { config.browserPaneMode == .browse }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let destination = selectedDestination {
                columnHeader
                Divider()
                fileList
                if let error = errorMessage {
                    errorBar(error)
                }
                dropZone(for: destination)
            }
        }
    }

    private var sectionTitle: String {
        if !isBrowse { return "Recent Uploads" }
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

    // MARK: Column header

    private var columnHeader: some View {
        HStack(spacing: 0) {
            if isBrowse && canGoBack {
                Button { browseBack() } label: {
                    Image(systemName: "chevron.backward").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back")
                .padding(.trailing, 10)
            }

            columnSortButton("Name", sorts: [.nameAscending, .nameDescending])
                .frame(maxWidth: .infinity, alignment: .leading)
            columnSortButton("Date", sorts: [.recentFirst])
                .frame(width: Col.date, alignment: .leading)
            Text("Size")
                .frame(width: Col.size, alignment: .trailing)
            optionsMenu
                .frame(width: Col.actions, alignment: .center)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// A clickable column header that applies one of the given sorts and shows
    /// the active-direction caret. The Name column toggles A↔Z.
    private func columnSortButton(_ title: String, sorts: [BrowserSort]) -> some View {
        let active = sorts.contains(browseSort)
        return Button {
            if sorts == [.nameAscending, .nameDescending] {
                browseSortOverride = (browseSort == .nameAscending) ? .nameDescending : .nameAscending
            } else if let first = sorts.first {
                browseSortOverride = first
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                if active {
                    Image(systemName: browseSort == .nameDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isBrowse)
    }

    /// Hamburger menu at the right of the column header: sort, view mode, and
    /// (in Browse) the folder / destination actions.
    private var optionsMenu: some View {
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
            Divider()
            Picker("View", selection: Binding(
                get: { config.browserPaneMode },
                set: { config.browserPaneMode = $0 }
            )) {
                Label("Browse Folders", systemImage: "folder").tag(BrowserPaneMode.browse)
                Label("Recent (All)", systemImage: "clock").tag(BrowserPaneMode.recentAll)
            }
            .pickerStyle(.inline)
            if isBrowse {
                Divider()
                Button {
                    newFolderName = ""
                    showNewFolderPrompt = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
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
            }
        } label: {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("View options")
    }

    // MARK: File list

    @ViewBuilder
    private var fileList: some View {
        if isBrowse {
            browseList
        } else {
            recentAllList
        }
    }

    @ViewBuilder
    private var browseList: some View {
        if isLoadingList && browseFolders.isEmpty && browseItems.isEmpty {
            loadingState
        } else if let browseError, browseFolders.isEmpty && browseItems.isEmpty {
            browseErrorView(browseError)
        } else if browseFolders.isEmpty && browseItems.isEmpty && !isLoadingList {
            emptyState(browsePrefix == rootPrefix ? "No files yet" : "Empty folder")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(browseFolders) { folder in
                        MacFolderRow(name: folderDisplayName(folder))
                            .onTapGesture { drillInto(folder) }
                        rowDivider
                    }
                    ForEach(browseItems) { item in
                        fileRow(for: item, badge: nil)
                            .id(item.object.id)
                        rowDivider
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var recentAllList: some View {
        if isLoadingList && recentItems.isEmpty {
            loadingState
        } else if recentItems.isEmpty && !isLoadingList {
            emptyState("No files yet")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(recentItems) { item in
                            fileRow(for: item, badge: item.destination.name)
                                .id(item.object.id)
                            rowDivider
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: recentItems.first?.id) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
            }
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 58).opacity(0.5)
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown while a destination/folder loads and there's nothing to display yet
    /// — mirrors the iOS browser so switching location clears to a spinner
    /// instead of lingering on the previous contents.
    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Drop zone + error

    private func dropZone(for destination: Destination) -> some View {
        DropZoneView(
            isTargeted: $isTargeted,
            isUploading: isUploading,
            uploadTasks: uploadTasks,
            targetName: sectionTitle
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
    }

    private func errorBar(_ error: String) -> some View {
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
        .padding(.top, 8)
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

    private func fileRow(for item: RecentItem, badge: String?) -> some View {
        FileRowView(
            object: item.object,
            previewURL: previewURL(for: item),
            badge: badge,
            isSelected: selectedItemID == item.object.id,
            isDownloading: downloadingObjectKey == item.object.key,
            downloadProgress: downloadingObjectKey == item.object.key ? downloadProgress : 0,
            onSelect: { selectedItemID = item.object.id }
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
        navigateBrowse(to: folder.prefix)
    }

    private func browseBack() {
        guard canGoBack else { return }
        let trimmed = browsePrefix.hasSuffix("/") ? String(browsePrefix.dropLast()) : browsePrefix
        var parent = (trimmed as NSString).deletingLastPathComponent
        if !parent.isEmpty { parent += "/" }
        navigateBrowse(to: parent)   // "" == bucket root
    }

    /// Moves the browser to a new folder: clears the current contents and shows
    /// the loading spinner immediately (rather than lingering on the previous
    /// folder while the fetch runs), then loads.
    private func navigateBrowse(to prefix: String) {
        browseFolders = []
        browseItems = []
        browseError = nil
        isLoadingList = true
        browsePrefix = prefix
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

    /// Opens the Settings destination editor pre-filled from the current browse
    /// view — same account, bucket, credentials and options as the selected
    /// destination, with the name, path and (when it tracks the folder) the
    /// public URL swapped to the current folder. Nothing is saved until the user
    /// presses Add, so they can review or tweak first.
    private func createDestinationHere() {
        guard let destination = selectedDestination else { return }
        var copy = destination
        copy.id = UUID()
        let baseName = folderDisplayName(S3Folder(prefix: browsePrefix)).isEmpty
            ? destination.name
            : folderDisplayName(S3Folder(prefix: browsePrefix))
        let names = config.destinations.map(\.name)
        copy.name = names.contains(baseName) ? ConfigStore.copyName(baseName, existing: names) : baseName
        copy.publicUrlBase = Self.rewrittenPublicUrlBase(
            copy.publicUrlBase, from: destination.pathPrefix, to: browsePrefix)
        copy.pathPrefix = browsePrefix
        copy.sortOrder = destination.sortOrder + 1
        config.pendingDuplicate = copy   // opens editor pre-filled, awaiting Add
        openSettings()
        openNativeSettings()
    }

    /// Rewrites a destination's public URL when it's cloned to a sibling folder.
    /// If the URL ends with the original prefix path (or just its last folder
    /// segment) that suffix is swapped for the new folder — e.g. cloning
    /// `shots/` → `backups/` turns `cdn.cjri.uk/shots` into `cdn.cjri.uk/backups`.
    /// URLs that don't visibly track the folder are left untouched.
    static func rewrittenPublicUrlBase(_ base: String, from oldPrefix: String, to newPrefix: String) -> String {
        guard !base.isEmpty else { return base }
        func trimSlashes(_ s: String) -> String {
            var t = s
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        let trimmedBase = trimSlashes(base)
        let oldPath = trimSlashes(oldPrefix)   // e.g. "media/shots"
        let newPath = trimSlashes(newPrefix)   // e.g. "media/backups"

        // 1. The whole old prefix path appears at the end of the URL.
        if !oldPath.isEmpty, trimmedBase.hasSuffix("/" + oldPath) {
            return String(trimmedBase.dropLast(oldPath.count)) + newPath
        }
        // 2. Only the old prefix's last folder segment appears at the end.
        let oldSeg = (oldPath as NSString).lastPathComponent
        let newSeg = (newPath as NSString).lastPathComponent
        if !oldSeg.isEmpty, !newSeg.isEmpty, trimmedBase.hasSuffix("/" + oldSeg) {
            return String(trimmedBase.dropLast(oldSeg.count)) + newSeg
        }
        // 3. URL doesn't track the folder — leave it for the user to adjust.
        return base
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

// MARK: - Brand logo

/// The ShareMaster mark: a paper plane flying out of an open box, composited
/// from the two icon layers so it matches the app icon.
struct ShareMasterLogo: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Image("LogoBox")
                    .resizable()
                    .scaledToFit()
                    .frame(width: s * 0.78, height: s * 0.78)
                    .offset(x: -s * 0.12, y: s * 0.16)
                Image("LogoPlane")
                    .resizable()
                    .scaledToFit()
                    .frame(width: s * 0.52, height: s * 0.52)
                    .offset(x: s * 0.30, y: -s * 0.30)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Header action button

/// A bordered, rounded icon button used in the header action row.
struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var isBusy: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: 34, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - Shared table layout

/// Fixed column widths so the header, folder rows and file rows all line up.
enum Col {
    static let date: CGFloat = 132
    static let size: CGFloat = 66
    static let actions: CGFloat = 34
}

/// The curated set of destination icons and colours the user can pick from in
/// Settings. Symbols and tints are stored on the destination by name.
enum DestinationIcon {
    static let symbols = [
        "folder.fill", "photo.fill", "camera.fill", "doc.fill",
        "archivebox.fill", "tray.full.fill", "icloud.fill", "star.fill",
        "film.fill", "music.note", "globe", "cube.box.fill",
        "paintbrush.fill", "hammer.fill", "cart.fill", "shippingbox.fill"
    ]

    /// Ordered palette; the key is what gets stored on the destination.
    static let tints: [(name: String, color: Color)] = [
        ("blue", .blue), ("green", .green), ("orange", .orange), ("red", .red),
        ("purple", .purple), ("pink", .pink), ("teal", .teal),
        ("indigo", .indigo), ("yellow", .yellow), ("gray", .gray)
    ]

    static func color(_ name: String?) -> Color {
        tints.first { $0.name == name }?.color ?? .blue
    }

    static let defaultSymbol = "folder.fill"

    /// A stable default tint from the id so uncustomised destinations still read
    /// as distinct coloured folders (rather than all identical).
    static func defaultTint(for id: UUID) -> String {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return tints[sum % tints.count].name
    }
}

/// The icon + colour to draw for a destination: the user's choice, else a
/// folder tinted stably from the id.
func destinationIconStyle(_ destination: Destination) -> (symbol: String, color: Color) {
    let symbol = destination.iconSymbol ?? DestinationIcon.defaultSymbol
    let tint = destination.iconTint ?? DestinationIcon.defaultTint(for: destination.id)
    return (symbol, DestinationIcon.color(tint))
}

// MARK: - Destination sidebar row

struct DestinationRow: View {
    let destination: Destination
    var isSelected: Bool = false
    var isDropTarget: Bool = false

    var body: some View {
        let style = destinationIconStyle(destination)
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(style.color.gradient)
                Image(systemName: style.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)

            Text(destination.name.isEmpty ? "Untitled" : destination.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDropTarget ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(rowBackground)
        )
        .help(subtitle)
        .animation(.easeInOut(duration: 0.1), value: isDropTarget)
    }

    private var rowBackground: Color {
        if isDropTarget { return Color.accentColor }
        if isSelected { return Color.primary.opacity(0.08) }
        return .clear
    }

    private var subtitle: String {
        let path = destination.pathPrefix.isEmpty ? "" : "/\(destination.pathPrefix)"
        return "\(destination.bucket)\(path)"
    }
}

// MARK: - Browser folder row

struct MacFolderRow: View {
    let name: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 32, height: 32)

                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("—")
                .frame(width: Col.date, alignment: .leading)
                .foregroundStyle(.secondary)
            Text("—")
                .frame(width: Col.size, alignment: .trailing)
                .foregroundStyle(.secondary)
            Spacer().frame(width: Col.actions)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

struct DropZoneView: View {
    @Binding var isTargeted: Bool
    let isUploading: Bool
    let uploadTasks: [UploadTask]
    var targetName: String = ""

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
                HStack(spacing: 10) {
                    Image(systemName: isTargeted ? "arrow.down.circle.fill" : "icloud.and.arrow.up")
                        .font(.system(size: 20))
                        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    Text(isTargeted
                         ? "Drop to upload"
                         : (targetName.isEmpty ? "Drop here or click to upload" : "Drop here to upload to \(targetName)"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 66)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [6, 4])
                )
        )
        .contentShape(Rectangle())
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
    var isSelected: Bool = false
    let isDownloading: Bool
    let downloadProgress: Double
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onDelete: () async -> Void
    /// The Bool is true when the user option-clicked (choose location).
    let onDownload: (Bool) async -> Void
    let onPreview: () -> Void

    @State private var isHovered = false
    @State private var isDeleting = false
    @State private var isCopied = false

    private var primaryText: Color { isSelected ? .white : .primary }
    private var secondaryText: Color { isSelected ? Color.white.opacity(0.85) : .secondary }
    private var showActions: Bool { isHovered || isSelected || isDeleting || isDownloading }

    var body: some View {
        HStack(spacing: 0) {
            // Name column
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(object.filename)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isDownloading {
                        ProgressView(value: downloadProgress)
                            .progressViewStyle(ActiveProgressViewStyle(height: 5))
                            .frame(maxWidth: 160)
                    } else if let badge {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((isSelected ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.15)), in: Capsule())
                            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    }
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(dateString)
                .frame(width: Col.date, alignment: .leading)
                .foregroundStyle(secondaryText)
            Text(formatSize(object.size))
                .frame(width: Col.size, alignment: .trailing)
                .foregroundStyle(secondaryText)
            Spacer().frame(width: Col.actions)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(rowBackground)
        .overlay(alignment: .trailing) { actionCluster }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { if !isDownloading { onPreview() } }
        .onTapGesture { onSelect() }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let previewURL {
            CachedAsyncImage(url: previewURL) { state in
                switch state {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo").foregroundStyle(.secondary)
                case .loading:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(fileTint.opacity(0.12))
                Image(systemName: iconForFile(object.filename))
                    .font(.system(size: 14))
                    .foregroundStyle(fileTint)
            }
            .frame(width: 32, height: 32)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor
        } else if isHovered {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }

    private var actionCluster: some View {
        HStack(spacing: 2) {
            actionButton(isCopied ? "checkmark.circle.fill" : "link",
                         help: "Copy Link",
                         tint: isCopied ? Color(nsColor: .systemGreen) : nil) {
                if !isDeleting && !isDownloading {
                    onCopy()
                    Task { @MainActor in
                        withAnimation(.easeInOut(duration: 0.15)) { isCopied = true }
                        try? await Task.sleep(for: .seconds(1))
                        withAnimation(.easeInOut(duration: 0.15)) { isCopied = false }
                    }
                }
            }
            actionButton("arrow.down.to.line", help: "Download (⌥-click to choose location)") {
                let choosePanel = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
                Task { await onDownload(choosePanel) }
            }
            actionButton("eye", help: "Preview") {
                if !isDownloading { onPreview() }
            }
            Button {
                Task {
                    isDeleting = true
                    await onDelete()
                    isDeleting = false
                }
            } label: {
                Group {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                            .foregroundStyle(isSelected ? Color.white : Color(nsColor: .systemRed))
                    }
                }
                .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Delete")
            .disabled(isDeleting || isDownloading)
        }
        .padding(.trailing, 12)
        .padding(.leading, 24)
        .padding(.vertical, 3)
        // Opaque, left-faded backing so the buttons cleanly cover the Size
        // column behind them instead of letting the text bleed through.
        .background(clusterBacking)
        .opacity(showActions ? 1 : 0)
        .allowsHitTesting(showActions)
    }

    private var clusterBacking: some View {
        let base = isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor)
        return LinearGradient(
            stops: [
                .init(color: base.opacity(0), location: 0),
                .init(color: base, location: 0.35),
                .init(color: base, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func actionButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(tint ?? (isSelected ? Color.white : Color.secondary))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(isDeleting || isDownloading)
    }

    private var fileTint: Color {
        switch (object.filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "svg": return .blue
        case "mp4", "mov", "avi": return .purple
        case "mp3", "wav", "m4a": return .pink
        case "pdf": return .red
        case "zip", "rar", "7z": return .orange
        default: return .secondary
        }
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy h:mm a"
        return f.string(from: object.lastModified)
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
