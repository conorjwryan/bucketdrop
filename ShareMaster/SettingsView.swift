//
//  SettingsView.swift
//  ShareMaster
//
//  Created by Conor Ryan on 02/07/26.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    private enum Tab: Hashable {
        case general, accounts, destinations, sync, about
    }

    var config = ConfigStore.shared
    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "key") }
                .tag(Tab.accounts)
            DestinationsSettingsView()
                .tabItem { Label("Destinations", systemImage: "tray.full") }
                .tag(Tab.destinations)
            SyncSettingsView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud") }
                .tag(Tab.sync)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 520, height: 540)
        // A duplicate started from the popover lands on the Destinations tab,
        // where DestinationsSettingsView opens the editor with it.
        .onAppear {
            if config.pendingDuplicate != nil { selection = .destinations }
        }
        .onChange(of: config.pendingDuplicate) { _, pending in
            if pending != nil { selection = .destinations }
        }
        .task {
            // The Settings window can stay open indefinitely, and the
            // keychain posts no change notifications — refresh on open, then
            // poll so accounts/destinations edited on other devices appear
            // while the window is up. Cancelled when it closes.
            config.refreshFromCloud()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                config.refreshFromCloud()
            }
        }
    }
}

// MARK: - Accounts

struct AccountsSettingsView: View {
    var config = ConfigStore.shared

    @State private var editingAccount: Account?
    @State private var isNewAccount = false
    /// When duplicating, the account whose stored credentials pre-fill the
    /// editor (the draft's own ID has none in the Keychain yet).
    @State private var duplicateSourceID: UUID?
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Filtered through the wordmark reveal: while concealed, accounts
            // used only by hidden destinations are absent here too, and the
            // "N dest." count ignores hidden destinations.
            if config.visibleAccounts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(config.visibleAccounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name.isEmpty ? "Untitled" : account.name)
                                    .fontWeight(.medium)
                                Text(account.endpoint.isEmpty ? "AWS • \(account.region)" : account.endpoint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text("\(config.visibleDestinationsUsing(accountId: account.id).count) dest.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button {
                                isNewAccount = false
                                editingAccount = account
                            } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                delete(account)
                            } label: { Image(systemName: "trash").foregroundStyle(.red) }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Duplicate") { duplicate(account) }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    isNewAccount = true
                    duplicateSourceID = nil
                    editingAccount = Account()
                } label: { Label("Add Account", systemImage: "plus") }
                Spacer()
            }
            .padding(10)
        }
        .sheet(item: $editingAccount) { account in
            AccountEditor(account: account, isNew: isNewAccount, secretsSourceID: duplicateSourceID)
        }
        .alert("Can't delete account", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No accounts yet")
                .foregroundStyle(.secondary)
            Text("Add credentials for an S3 provider (AWS, R2, MinIO…).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func duplicate(_ account: Account) {
        isNewAccount = true
        duplicateSourceID = account.id
        editingAccount = config.duplicateDraft(of: account)
    }

    private func delete(_ account: Account) {
        if !config.deleteAccount(id: account.id) {
            // Only name visible destinations — the delete still fails if a
            // concealed one uses the account, but we don't reveal it here.
            let names = config.visibleDestinationsUsing(accountId: account.id).map(\.name).joined(separator: ", ")
            deleteError = "\"\(account.name)\" is used by: \(names). Remove or reassign those destinations first."
        }
    }
}

struct AccountEditor: View {
    @Environment(\.dismiss) private var dismiss
    var config = ConfigStore.shared

    @State var account: Account
    let isNew: Bool
    /// Duplicating: the source account whose Keychain credentials pre-fill
    /// the fields. Save writes them under the draft's own ID.
    var secretsSourceID: UUID? = nil

    @State private var accessKeyId = ""
    @State private var secret = ""
    @State private var testBucket = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Name", text: $account.name, prompt: Text("AWS Prod"))
                SecureField("Access Key ID", text: $accessKeyId)
                SecureField("Secret Access Key", text: $secret)
                TextField("Region", text: $account.region, prompt: Text("us-east-1"))
            }

            Section {
                TextField("S3 Endpoint", text: $account.endpoint, prompt: Text("https://xxx.r2.cloudflarestorage.com"))
            } header: {
                Text("S3-Compatible (R2, MinIO, etc.)")
            } footer: {
                Text("For Cloudflare R2: paste the S3 API endpoint URL and set region to 'auto'. Leave blank for AWS.")
            }

            Section {
                TextField("Upload limit (MB/s)", value: $account.uploadCapMBps, format: .number, prompt: Text("Unlimited"))
                TextField("Download limit (MB/s)", value: $account.downloadCapMBps, format: .number, prompt: Text("Unlimited"))
                Picker("Concurrent parts", selection: $account.maxConcurrentParts) {
                    Text("Default (4)").tag(Int?.none)
                    ForEach([1, 2, 4, 6, 8, 12, 16], id: \.self) { n in
                        Text("\(n)").tag(Int?.some(n))
                    }
                }
            } header: {
                Text("Transfers")
            } footer: {
                Text("Large files transfer in multiple parts at once — more concurrent parts is faster on quick connections. Leave limits empty for unlimited speed. Destinations can override these settings.")
            }

            Section("Test Connection") {
                TextField("Test against bucket", text: $testBucket, prompt: Text("my-bucket"))
                HStack {
                    Button("Test") { testConnection() }
                        .disabled(isTesting || accessKeyId.isEmpty || secret.isEmpty || testBucket.isEmpty)
                    if isTesting { ProgressView().controlSize(.small) }
                    if let result = testResult {
                        switch result {
                        case .success:
                            Label("Connected!", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failure(let error):
                            Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).lineLimit(2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(account.name.isEmpty || accessKeyId.isEmpty || secret.isEmpty)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let sourceID = isNew ? secretsSourceID : account.id else { return }
        accessKeyId = config.accessKeyId(for: sourceID)
        secret = config.secret(for: sourceID)
        testBucket = config.destinationsUsing(accountId: sourceID).first?.bucket ?? ""
    }

    private func save() {
        if account.region.isEmpty { account.region = "us-east-1" }
        config.upsertAccount(account, accessKeyId: accessKeyId, secret: secret)
        dismiss()
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let cfg = config.testConfig(account: account, accessKeyId: accessKeyId, secret: secret, bucket: testBucket)
        Task {
            do {
                _ = try await S3Service.shared.listObjects(config: cfg)
                await MainActor.run { testResult = .success; isTesting = false }
            } catch {
                await MainActor.run { testResult = .failure(error.localizedDescription); isTesting = false }
            }
        }
    }
}

// MARK: - Destinations

struct DestinationsSettingsView: View {
    var config = ConfigStore.shared

    @State private var editingDestination: Destination?
    @State private var isNewDestination = false

    var body: some View {
        VStack(spacing: 0) {
            // Filtered through the wordmark reveal: while concealed, hidden
            // destinations are absent and the empty states read as a normal
            // fresh setup.
            if config.visibleAccounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.full").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("Add an account first")
                        .foregroundStyle(.secondary)
                    Text("Destinations need an account for their credentials.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if config.visibleDestinations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.full").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("No destinations yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(config.visibleDestinations) { destination in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(destination.name.isEmpty ? "Untitled" : destination.name)
                                    .fontWeight(.medium)
                                Text(subtitle(destination))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if destination.isHidden {
                                Image(systemName: "eye.slash")
                                    .foregroundStyle(.tertiary)
                                    .help("Hidden — revealed by clicking the ShareMaster word mark")
                            }
                            Image(systemName: destination.linkMode == .presigned ? "lock" : "globe")
                                .foregroundStyle(.tertiary)
                                .help(destination.linkMode == .presigned ? "Presigned links" : "Public links")
                            Button {
                                isNewDestination = false
                                editingDestination = destination
                            } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                config.deleteDestination(id: destination.id)
                            } label: { Image(systemName: "trash").foregroundStyle(.red) }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Duplicate") { duplicate(destination) }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    isNewDestination = true
                    editingDestination = Destination(accountId: config.visibleAccounts.first!.id)
                } label: { Label("Add Destination", systemImage: "plus") }
                    .disabled(config.visibleAccounts.isEmpty)
                Spacer()
            }
            .padding(10)
        }
        .sheet(item: $editingDestination) { destination in
            DestinationEditor(destination: destination, isNew: isNewDestination)
        }
        // A duplicate started from the popover's context menu: open the
        // editor with the ready-made draft.
        .onAppear(perform: consumePendingDuplicate)
        .onChange(of: config.pendingDuplicate) { _, _ in consumePendingDuplicate() }
    }

    private func duplicate(_ destination: Destination) {
        isNewDestination = true
        editingDestination = config.duplicateDraft(of: destination)
    }

    private func consumePendingDuplicate() {
        guard let draft = config.pendingDuplicate else { return }
        config.pendingDuplicate = nil
        isNewDestination = true
        editingDestination = draft
    }

    private func subtitle(_ d: Destination) -> String {
        let account = config.account(id: d.accountId)?.name ?? "—"
        let path = d.pathPrefix.isEmpty ? "" : "/\(d.pathPrefix)"
        return "\(account) • \(d.bucket)\(path)"
    }
}

struct DestinationEditor: View {
    @Environment(\.dismiss) private var dismiss
    var config = ConfigStore.shared

    @State var destination: Destination
    let isNew: Bool

    @State private var expiryPreset: ExpiryPreset = .d1
    @State private var customHours: Int = 24
    @State private var overrideTransfers = false

    enum ExpiryPreset: Hashable {
        case h1, h6, d1, d7, custom
        var seconds: Int? {
            switch self {
            case .h1: return 3_600
            case .h6: return 21_600
            case .d1: return 86_400
            case .d7: return 604_800
            case .custom: return nil
            }
        }
    }

    var body: some View {
        Form {
            Section("Destination") {
                TextField("Name", text: $destination.name, prompt: Text("Backups"))
                Picker("Account", selection: $destination.accountId) {
                    ForEach(config.visibleAccounts) { account in
                        Text(account.name.isEmpty ? "Untitled" : account.name).tag(account.id)
                    }
                }
                TextField("Bucket", text: $destination.bucket, prompt: Text("my-bucket"))
                TextField("Path Prefix", text: $destination.pathPrefix, prompt: Text("backups/"))
            }

            Section {
                TextField("Naming Template", text: $destination.namingTemplate, prompt: Text(NamingTemplate.default))
                LabeledContent("Example") {
                    Text(destination.pathPrefix + NamingTemplate.preview(destination.namingTemplate))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } header: {
                Text("Filename")
            } footer: {
                Text("Tokens: \(NamingTemplate.allTokens.joined(separator: "  "))")
            }

            Section("Sharing") {
                Toggle("Make uploaded files public (public-read ACL)", isOn: $destination.makePublic)
                Picker("Link mode", selection: $destination.linkMode) {
                    Text("Public URL").tag(LinkMode.publicUrl)
                    Text("Presigned URL").tag(LinkMode.presigned)
                }
                if destination.linkMode == .publicUrl {
                    TextField("Public URL Base", text: $destination.publicUrlBase, prompt: Text("https://static.example.com"))
                    Label {
                        Text("Public links require public access to be enabled on the provider dashboard (e.g. R2's public bucket / r2.dev URL or a custom domain), and that URL entered in Public URL Base above. Links will fail if either is missing.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Picker("Link expiry", selection: $expiryPreset) {
                        Text("1 hour").tag(ExpiryPreset.h1)
                        Text("6 hours").tag(ExpiryPreset.h6)
                        Text("24 hours").tag(ExpiryPreset.d1)
                        Text("7 days").tag(ExpiryPreset.d7)
                        Text("Custom").tag(ExpiryPreset.custom)
                    }
                    if expiryPreset == .custom {
                        Stepper("\(customHours) hours (max 168)", value: $customHours, in: 1...168)
                    }
                }
                Toggle("Copy link to clipboard after upload", isOn: $destination.copyOnUpload)
            }

            Section {
                Toggle("Hide from destination lists", isOn: $destination.isHidden)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Hidden destinations don't appear anywhere — the popover, the iOS app, the share sheet or these Settings — until revealed by tapping the ShareMaster word mark (in the popover or the iOS app). Accounts used only by hidden destinations are concealed with them.")
            }

            Section {
                Picker("Save downloads to", selection: Binding(
                    get: { destination.effectiveDownloadLocation },
                    set: { newValue in
                        destination.downloadLocation = newValue
                        if newValue == .custom && destination.downloadDirBookmark == nil {
                            chooseDownloadFolder()
                        }
                    }
                )) {
                    Text("Downloads folder").tag(DownloadLocation.downloads)
                    Text("Custom folder").tag(DownloadLocation.custom)
                    Text("Choose every time").tag(DownloadLocation.ask)
                }

                if destination.effectiveDownloadLocation == .custom {
                    LabeledContent("Folder") {
                        Text(downloadFolderLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Choose Folder…") { chooseDownloadFolder() }
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Option-click a file's download button to choose the location for that download, whatever this is set to.")
            }

            Section {
                Toggle("Override account transfer settings", isOn: $overrideTransfers)
                if overrideTransfers {
                    TextField("Upload limit (MB/s)", value: $destination.uploadCapMBps, format: .number, prompt: Text("Account default"))
                    TextField("Download limit (MB/s)", value: $destination.downloadCapMBps, format: .number, prompt: Text("Account default"))
                    Picker("Concurrent parts", selection: $destination.maxConcurrentParts) {
                        Text("Account default").tag(Int?.none)
                        ForEach([1, 2, 4, 6, 8, 12, 16], id: \.self) { n in
                            Text("\(n)").tag(Int?.some(n))
                        }
                    }
                }
            } header: {
                Text("Transfers")
            } footer: {
                Text("Any field left empty keeps the account's setting for just that value.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(destination.name.isEmpty || destination.bucket.isEmpty)
            }
        }
        .onAppear(perform: loadExpiry)
    }

    private var downloadFolderLabel: String {
        guard destination.downloadDirBookmark != nil else { return "Downloads" }
        let (url, _) = ConfigStore.downloadDirectory(for: destination)
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Security-scoped bookmark keeps write access across launches.
        destination.downloadDirBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func loadExpiry() {
        overrideTransfers = destination.uploadCapMBps != nil
            || destination.downloadCapMBps != nil
            || destination.maxConcurrentParts != nil
        switch destination.presignExpirySeconds {
        case 3_600: expiryPreset = .h1
        case 21_600: expiryPreset = .h6
        case 86_400: expiryPreset = .d1
        case 604_800: expiryPreset = .d7
        default:
            expiryPreset = .custom
            customHours = max(1, min(168, destination.presignExpirySeconds / 3_600))
        }
    }

    private func save() {
        if destination.linkMode == .presigned {
            destination.presignExpirySeconds = expiryPreset.seconds ?? (customHours * 3_600)
        }
        if !overrideTransfers {
            destination.uploadCapMBps = nil
            destination.downloadCapMBps = nil
            destination.maxConcurrentParts = nil
        }
        config.upsertDestination(destination)
        dismiss()
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    var config = ConfigStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Keep window open when switching apps", isOn: Binding(
                    get: { config.pinPopover },
                    set: { config.pinPopover = $0 }
                ))
            } footer: {
                Text("When off, the ShareMaster window closes as soon as you click another window or switch apps. When on, it stays on top until you close it yourself.")
            }

            Section {
                Picker("Recent uploads list", selection: Binding(
                    get: { config.recentScope },
                    set: { config.recentScope = $0 }
                )) {
                    Text("Per destination").tag(RecentScope.perDestination)
                    Text("Combined (all destinations)").tag(RecentScope.combined)
                }
                .pickerStyle(.radioGroup)

                Picker("Show at most", selection: Binding(
                    get: { config.recentLimit },
                    set: { config.recentLimit = $0 }
                )) {
                    ForEach([5, 10, 25, 50], id: \.self) { n in
                        Text("\(n) files").tag(n)
                    }
                }
            } footer: {
                Text("Per destination shows only the selected destination's files. Combined merges files from every destination with a badge showing where each one lives. The list only loads while expanded, and shows at most the number of files chosen here — keeping list requests down on providers that charge per operation.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sync

struct SyncSettingsView: View {
    var config = ConfigStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Sync via iCloud", isOn: Binding(
                    get: { config.iCloudSyncEnabled },
                    set: { config.iCloudSyncEnabled = $0 }
                ))
            } footer: {
                Text("Shares your accounts and destinations with your other devices through iCloud Keychain. Requires the same iCloud account with iCloud Keychain enabled on each device. When off, this Mac keeps its local configuration and neither publishes nor adopts changes; turning it back on picks up the newest configuration and publishes this Mac's.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section("ShareMaster") {
                HStack {
                    AsyncImage(url: URL(string: "https://github.com/conorjwryan.png")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(Color(nsColor: .quaternaryLabelColor))
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Conor Ryan").font(.subheadline).fontWeight(.medium)
                        Text("Development").font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer()

                    Link("@conorjwryan", destination: URL(string: "https://x.com/conorjwryan")!)
                        .font(.caption)
                }
            }

            Section {
                HStack {
                    AsyncImage(url: URL(string: "https://github.com/fayazara.png")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(Color(nsColor: .quaternaryLabelColor))
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fayaz Ahmed").font(.subheadline).fontWeight(.medium)
                        Text("Built on the foundation of BucketDrop")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Link("@fayazara", destination: URL(string: "https://x.com/fayazara")!)
                            .font(.caption)
                        Link("Original project", destination: URL(string: "https://github.com/fayazara/bucketdrop")!)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("Made in India • Improved in Vietnam")
                    .frame(maxWidth: .infinity)
            }

            Section {
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    HStack {
                        Spacer()
                        Label("Quit ShareMaster", systemImage: "power")
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
}
