//
//  SettingsView.swift
//  BucketDrop
//
//  Created by Fayaz Ahmed Aralikatti on 12/01/26.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "key") }
            DestinationsSettingsView()
                .tabItem { Label("Destinations", systemImage: "tray.full") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 540)
    }
}

// MARK: - Accounts

struct AccountsSettingsView: View {
    var config = ConfigStore.shared

    @State private var editingAccount: Account?
    @State private var isNewAccount = false
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 0) {
            if config.accounts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(config.accounts) { account in
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
                            Text("\(config.destinationsUsing(accountId: account.id).count) dest.")
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
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    isNewAccount = true
                    editingAccount = Account()
                } label: { Label("Add Account", systemImage: "plus") }
                Spacer()
            }
            .padding(10)
        }
        .sheet(item: $editingAccount) { account in
            AccountEditor(account: account, isNew: isNewAccount)
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

    private func delete(_ account: Account) {
        if !config.deleteAccount(id: account.id) {
            let names = config.destinationsUsing(accountId: account.id).map(\.name).joined(separator: ", ")
            deleteError = "\"\(account.name)\" is used by: \(names). Remove or reassign those destinations first."
        }
    }
}

struct AccountEditor: View {
    @Environment(\.dismiss) private var dismiss
    var config = ConfigStore.shared

    @State var account: Account
    let isNew: Bool

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
        guard !isNew else { return }
        accessKeyId = config.accessKeyId(for: account.id)
        secret = config.secret(for: account.id)
        testBucket = config.destinationsUsing(accountId: account.id).first?.bucket ?? ""
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
            if config.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.full").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("Add an account first")
                        .foregroundStyle(.secondary)
                    Text("Destinations need an account for their credentials.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if config.destinations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.full").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("No destinations yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(config.sortedDestinations) { destination in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(destination.name.isEmpty ? "Untitled" : destination.name)
                                    .fontWeight(.medium)
                                Text(subtitle(destination))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
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
                    }
                }
            }

            Divider()
            HStack {
                Button {
                    isNewDestination = true
                    editingDestination = Destination(accountId: config.accounts.first!.id)
                } label: { Label("Add Destination", systemImage: "plus") }
                    .disabled(config.accounts.isEmpty)
                Spacer()
            }
            .padding(10)
        }
        .sheet(item: $editingDestination) { destination in
            DestinationEditor(destination: destination, isNew: isNewDestination)
        }
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
                    ForEach(config.accounts) { account in
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

    private func loadExpiry() {
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
                Text("When off, the BucketDrop window closes as soon as you click another window or switch apps. When on, it stays on top until you close it yourself.")
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
            } footer: {
                Text("Per destination shows only the selected destination's files. Combined merges files from every destination with a badge showing where each one lives.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        Form {
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
                        Link("@fayazara", destination: URL(string: "https://x.com/fayazara")!).font(.caption)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Conor Ryan").font(.subheadline).fontWeight(.medium)
                        Link("@conorjwryan", destination: URL(string: "https://x.com/conorjwryan")!).font(.caption)
                    }

                    AsyncImage(url: URL(string: "https://github.com/conorjwryan.png")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(Color(nsColor: .quaternaryLabelColor))
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                }

                HStack {
                    Spacer()
                    Text("Made in India • Improved in Vietnam")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Section {
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    HStack {
                        Spacer()
                        Label("Quit BucketDrop", systemImage: "power")
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
