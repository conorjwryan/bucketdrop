//
//  IOSSettingsView.swift
//  ShareMasterIOS
//
//  Accounts & Destinations editors, mirroring the macOS settings but as
//  iOS-native forms. Secrets go to the shared keychain; everything else to
//  the App Group defaults, so the share extension picks changes up
//  immediately.
//

import SwiftUI

struct IOSSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = ConfigStore.shared

    @State private var editingAccount: Account?
    @State private var addingAccount = false
    @State private var duplicatingAccount: Account?
    @State private var editingDestination: Destination?
    @State private var addingDestination = false
    @State private var duplicatingDestination: Destination?

    var body: some View {
        @Bindable var config = config
        NavigationStack {
            List {
                Section {
                    Toggle("Transfer on Mobile Data", isOn: $config.allowsCellularUploads)
                    Toggle("Skip Mobile Data Warnings", isOn: $config.suppressCellularWarnings)
                        .disabled(!config.allowsCellularUploads)
                    Toggle("iCloud Sync", isOn: $config.iCloudSyncEnabled)
                } header: {
                    Text("Sync")
                } footer: {
                    Text("With Mobile Data off, files upload and download only over Wi-Fi — browsing, previews, and copying links work anywhere. With it on, you'll see how much data a transfer will use before it starts, unless warnings are skipped. iCloud Sync shares your accounts and destinations between devices through iCloud Keychain.")
                }

                Section {
                    Toggle("Full-Size Image Previews", isOn: $config.rendersFullImagePreviews)
                    Toggle("Tap to Preview on Mobile Data", isOn: $config.requiresTapForCellularPreviews)
                } header: {
                    Text("Previews")
                } footer: {
                    Text("Full-size previews decode the original image instead of a smaller display copy. On mobile data, tap-to-preview stops images from downloading until you choose to load them.")
                }

                DownloadsSettingsSection()

                // Both sections filter through the wordmark reveal: with it
                // off, hidden destinations and their dedicated accounts are
                // absent here too, so Settings looks like an ordinary setup.
                Section("Accounts") {
                    ForEach(config.visibleAccounts) { account in
                        Button {
                            editingAccount = account
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name.isEmpty ? "Untitled" : account.name)
                                    .foregroundStyle(.primary)
                                Text(account.endpoint.isEmpty ? "AWS S3 · \(account.region)" : account.endpoint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                _ = config.deleteAccount(id: account.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(!config.destinationsUsing(accountId: account.id).isEmpty)
                        }
                        .contextMenu {
                            Button {
                                duplicatingAccount = account
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                        }
                    }
                    Button {
                        addingAccount = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                }

                Section("Destinations") {
                    ForEach(config.visibleDestinations) { destination in
                        Button {
                            editingDestination = destination
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(destination.name.isEmpty ? "Untitled" : destination.name)
                                        .foregroundStyle(.primary)
                                    Text(destination.bucket + (destination.pathPrefix.isEmpty ? "" : "/\(destination.pathPrefix)"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if destination.isHidden {
                                    Spacer()
                                    Image(systemName: "eye.slash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                config.deleteDestination(id: destination.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                duplicatingDestination = destination
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                        }
                    }
                    Button {
                        addingDestination = true
                    } label: {
                        Label("Add Destination", systemImage: "plus")
                    }
                    .disabled(config.visibleAccounts.isEmpty)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $addingAccount) {
                AccountEditorView(account: nil)
            }
            .sheet(item: $editingAccount) { account in
                AccountEditorView(account: account)
            }
            .sheet(item: $duplicatingAccount) { account in
                AccountEditorView(duplicating: account)
            }
            .sheet(isPresented: $addingDestination) {
                DestinationEditorView(destination: nil)
            }
            .sheet(item: $editingDestination) { destination in
                DestinationEditorView(destination: destination)
            }
            .sheet(item: $duplicatingDestination) { destination in
                DestinationEditorView(duplicating: destination)
            }
        }
    }
}

// MARK: - Account editor

struct AccountEditorView: View {
    let account: Account?   // nil = create

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Account
    @State private var accessKeyId: String
    @State private var secret: String
    private let isNew: Bool

    init(account: Account?) {
        self.account = account
        let existing = account ?? Account()
        _draft = State(initialValue: existing)
        isNew = account == nil
        if let account {
            _accessKeyId = State(initialValue: ConfigStore.shared.accessKeyId(for: account.id))
            _secret = State(initialValue: ConfigStore.shared.secret(for: account.id))
        } else {
            _accessKeyId = State(initialValue: "")
            _secret = State(initialValue: "")
        }
    }

    /// Duplicate flow: a fresh draft copied from `source` with the
    /// credentials pre-filled; nothing is stored until Save.
    init(duplicating source: Account) {
        account = nil
        isNew = true
        _draft = State(initialValue: ConfigStore.shared.duplicateDraft(of: source))
        _accessKeyId = State(initialValue: ConfigStore.shared.accessKeyId(for: source.id))
        _secret = State(initialValue: ConfigStore.shared.secret(for: source.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $draft.name)
                    TextField("Region (e.g. us-east-1)", text: $draft.region)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Endpoint (empty for AWS)", text: $draft.endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    TextField("Access Key ID", text: $accessKeyId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Secret Access Key", text: $secret)
                } header: {
                    Text("Credentials")
                } footer: {
                    Text("Stored in the keychain and shared with the share extension.")
                }
                Section {
                    TextField("Upload limit (MB/s)", value: $draft.uploadCapMBps, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Download limit (MB/s)", value: $draft.downloadCapMBps, format: .number)
                        .keyboardType(.decimalPad)
                    Picker("Concurrent parts", selection: $draft.maxConcurrentParts) {
                        Text("Default (4)").tag(Int?.none)
                        ForEach([1, 2, 4, 6, 8, 12, 16], id: \.self) { n in
                            Text("\(n)").tag(Int?.some(n))
                        }
                    }
                } header: {
                    Text("Transfers")
                } footer: {
                    Text("These account defaults apply unless a destination overrides them. Leave limits empty for unlimited speed.")
                }
            }
            .navigationTitle(isNew ? "New Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        ConfigStore.shared.upsertAccount(
                            draft,
                            accessKeyId: accessKeyId.isEmpty ? nil : accessKeyId,
                            secret: secret.isEmpty ? nil : secret
                        )
                        dismiss()
                    }
                    .disabled(draft.name.isEmpty || (isNew && (accessKeyId.isEmpty || secret.isEmpty)))
                }
            }
        }
    }
}

// MARK: - Destination editor

struct DestinationEditorView: View {
    let destination: Destination?   // nil = create

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Destination
    @State private var overrideTransfers: Bool
    private let isNew: Bool

    init(destination: Destination?) {
        self.destination = destination
        isNew = destination == nil
        let fallbackAccount = ConfigStore.shared.visibleAccounts.first?.id ?? UUID()
        let existing = destination ?? Destination(accountId: fallbackAccount)
        _draft = State(initialValue: existing)
        _overrideTransfers = State(initialValue: Self.hasTransferOverrides(existing))
    }

    /// Duplicate flow: a fresh draft copied from `source`; nothing is stored
    /// until Save.
    init(duplicating source: Destination) {
        destination = nil
        isNew = true
        let copy = ConfigStore.shared.duplicateDraft(of: source)
        _draft = State(initialValue: copy)
        _overrideTransfers = State(initialValue: Self.hasTransferOverrides(copy))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("Name", text: $draft.name)
                    Picker("Account", selection: $draft.accountId) {
                        ForEach(ConfigStore.shared.visibleAccounts) { account in
                            Text(account.name.isEmpty ? "Untitled" : account.name).tag(account.id)
                        }
                    }
                    TextField("Bucket", text: $draft.bucket)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Path prefix (optional)", text: $draft.pathPrefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Naming template", text: $draft.namingTemplate)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Naming")
                } footer: {
                    Text("Preview: \(NamingTemplate.preview(draft.namingTemplate))\nTokens: \(NamingTemplate.allTokens.joined(separator: " "))")
                }

                Section {
                    Picker("Sort files by", selection: $draft.defaultBrowserSort) {
                        ForEach(BrowserSort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } header: {
                    Text("Browsing")
                } footer: {
                    Text("How the file browser orders this destination's folders by default. You can still change the order for a single visit from the \u{2026} menu.")
                }

                Section {
                    Toggle("Hide from main list", isOn: $draft.isHidden)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Hidden destinations disappear from the main list and from Settings. Tap the ShareMaster word mark on the main screen to reveal them everywhere.")
                }

                Section("Link") {
                    Picker("Link type", selection: $draft.linkMode) {
                        Text("Public URL").tag(LinkMode.publicUrl)
                        Text("Presigned").tag(LinkMode.presigned)
                    }
                    if draft.linkMode == .publicUrl {
                        TextField("Public URL base (optional)", text: $draft.publicUrlBase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Toggle("Make uploads public", isOn: $draft.makePublic)
                    } else {
                        Picker("Expires after", selection: $draft.presignExpirySeconds) {
                            Text("1 hour").tag(3_600)
                            Text("1 day").tag(86_400)
                            Text("1 week").tag(604_800)
                        }
                    }
                    Toggle("Copy link to clipboard after upload", isOn: $draft.copyOnUpload)
                }

                Section {
                    Toggle("Override account transfer settings", isOn: $overrideTransfers)
                    TextField("Upload limit (MB/s)", value: $draft.uploadCapMBps, format: .number)
                        .keyboardType(.decimalPad)
                        .disabled(!overrideTransfers)
                    TextField("Download limit (MB/s)", value: $draft.downloadCapMBps, format: .number)
                        .keyboardType(.decimalPad)
                        .disabled(!overrideTransfers)
                    Picker("Concurrent parts", selection: $draft.maxConcurrentParts) {
                        Text("Account default").tag(Int?.none)
                        ForEach([1, 2, 4, 6, 8, 12, 16], id: \.self) { n in
                            Text("\(n)").tag(Int?.some(n))
                        }
                    }
                    .disabled(!overrideTransfers)
                } header: {
                    Text("Transfers")
                } footer: {
                    Text("Destinations normally inherit their account's transfer defaults. Turn this on to tune just this destination.")
                }
            }
            .navigationTitle(isNew ? "New Destination" : "Edit Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                    .disabled(draft.name.isEmpty || draft.bucket.isEmpty)
                }
            }
        }
    }

    private static func hasTransferOverrides(_ destination: Destination) -> Bool {
        destination.uploadCapMBps != nil
            || destination.downloadCapMBps != nil
            || destination.maxConcurrentParts != nil
    }

    private func save() {
        if !overrideTransfers {
            draft.uploadCapMBps = nil
            draft.downloadCapMBps = nil
            draft.maxConcurrentParts = nil
        }
        ConfigStore.shared.upsertDestination(draft)
        dismiss()
    }
}

/// Downloads controls: where local copies live (Files-app-visible or
/// private) and a way to reclaim the space they use.
struct DownloadsSettingsSection: View {
    @State private var config = ConfigStore.shared
    @State private var store = DownloadStore.shared
    @State private var confirmRemoveAll = false

    var body: some View {
        @Bindable var config = config
        Section {
            Toggle("Show Downloads in Files App", isOn: Binding(
                get: { config.showsDownloadsInFilesApp },
                set: {
                    config.showsDownloadsInFilesApp = $0
                    store.applyRootChange()
                }
            ))
            if !store.isEmpty {
                Button("Remove All Downloads", role: .destructive) {
                    confirmRemoveAll = true
                }
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text(footerText)
        }
        .confirmationDialog(
            "Remove All Downloads?",
            isPresented: $confirmRemoveAll,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                store.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every downloaded copy from this device. Nothing is deleted from your buckets.")
        }
    }

    private var footerText: String {
        let visibility = "With Files App visibility on, downloads appear under On My iPhone → ShareMaster; off keeps them private to this app (Export still works)."
        guard !store.isEmpty else { return visibility }
        let size = ByteCountFormatter.string(fromByteCount: store.totalSize, countStyle: .file)
        return "Downloads are using \(size) on this device. " + visibility
    }
}
