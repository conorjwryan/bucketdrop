//
//  UploadMenu.swift
//  ShareMasterIOS
//
//  Toolbar "+" menu for uploading from within the app: pick photos/videos
//  from the library or any file from Files, then upload to a destination.
//  Uploads are handed to UploadManager so they run in the background while
//  the user keeps browsing — progress shows in the UploadStatusBar. When
//  used inside the bucket browser the destination is fixed and the upload
//  starts immediately; from the root list a destination picker sheet is
//  shown first. Destinations can copy links to the clipboard on completion.
//  Inside the bucket browser the menu also offers "New Folder", which
//  creates an S3 folder-marker object under the current prefix.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct UploadMenu: View {
    /// Upload straight to this destination when set; otherwise ask.
    var destination: Destination? = nil
    /// Key prefix to upload under (the folder open in the browser).
    /// nil uses the destination's configured path prefix.
    var keyPrefix: String? = nil
    /// Whether the destination picker includes hidden destinations —
    /// mirrors the main list's reveal state.
    var includeHidden = false
    /// Called after a successful upload (e.g. to refresh the object list).
    var onUploaded: () -> Void = {}

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var uploadRequest: UploadRequest?
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var newFolderError: String?

    var body: some View {
        Menu {
            Button {
                showPhotosPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("Choose Files", systemImage: "folder")
            }
            // Folders need a bucket to live in, so only offer this when the
            // menu is tied to a destination (i.e. inside the bucket browser).
            if destination != nil {
                Divider()
                Button {
                    newFolderName = ""
                    showNewFolderPrompt = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
                .textInputAutocapitalization(.never)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a folder in the current directory.")
        }
        .alert("Couldn't Create Folder", isPresented: .init(
            get: { newFolderError != nil },
            set: { if !$0 { newFolderError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(newFolderError ?? "")
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $photoSelection)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task {
                var urls: [URL] = []
                for item in items {
                    if let file = try? await item.loadTransferable(type: PickedFile.self) {
                        urls.append(file.url)
                    }
                }
                handlePicked(urls)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard let urls = try? result.get() else { return }
            handlePicked(urls.compactMap(Self.copyToTemp))
        }
        .sheet(item: $uploadRequest) { request in
            UploadDestinationPicker(
                files: request.files,
                includeHidden: includeHidden,
                onUploaded: onUploaded
            )
        }
    }

    /// Fixed destination: start uploading right away (the status bar takes
    /// over). Otherwise present the destination picker.
    private func handlePicked(_ files: [URL]) {
        guard !files.isEmpty else { return }
        if let destination {
            UploadManager.shared.start(files: files, destination: destination, keyPrefix: keyPrefix, onUploaded: onUploaded)
        } else {
            uploadRequest = UploadRequest(files: files)
        }
    }

    /// Creates an S3 "folder" (a zero-byte "/"-suffixed marker object) in
    /// the directory this menu is scoped to, then refreshes the listing.
    private func createFolder() {
        guard let destination,
              let config = ConfigStore.shared.s3Config(for: destination) else { return }
        let name = newFolderName
        Task {
            do {
                try await S3Service.shared.createFolder(
                    named: name,
                    under: keyPrefix ?? config.pathPrefix,
                    config: config
                )
                onUploaded()
            } catch {
                newFolderError = error.localizedDescription
            }
        }
    }

    /// fileImporter URLs are security-scoped and short-lived — copy them out.
    private nonisolated static func copyToTemp(_ url: URL) -> URL? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            return try PickedFile.tempCopy(of: url)
        } catch {
            return nil
        }
    }
}

private struct UploadRequest: Identifiable {
    let id = UUID()
    let files: [URL]
}

/// Imports a PhotosPicker item as a real file, keeping its original filename.
private struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            PickedFile(url: try tempCopy(of: received.file))
        }
    }

    /// Copies into a unique per-pick temp directory so identically-named
    /// files don't clash (mirrors the share extension's AttachmentLoader).
    nonisolated static func tempCopy(of url: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}

/// Destination picker sheet shown when the upload wasn't started from a
/// specific bucket. Picking a destination hands the batch to UploadManager
/// and dismisses — progress continues in the UploadStatusBar.
struct UploadDestinationPicker: View {
    let files: [URL]
    var includeHidden = false
    var onUploaded: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    private let config = ConfigStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section(files.count == 1 ? "Upload 1 file to" : "Upload \(files.count) files to") {
                    ForEach(config.sortedDestinations.filter { includeHidden || !$0.isHidden }) { destination in
                        Button {
                            UploadManager.shared.start(files: files, destination: destination, onUploaded: onUploaded)
                            dismiss()
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
                    }
                }
            }
            .navigationTitle("Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
