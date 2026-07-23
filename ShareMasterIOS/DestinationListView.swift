//
//  DestinationListView.swift
//  ShareMasterIOS
//
//  Root view: the list of configured destinations. Tapping one opens the
//  bucket browser; the gear opens Accounts & Destinations settings.
//

import SwiftUI

struct DestinationListView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var config = ConfigStore.shared
    @State private var uploads = UploadManager.shared
    @State private var downloads = DownloadManager.shared
    @State private var showSettings = false
    @State private var pendingDestinationRemoval: Destination?

    private var visibleDestinations: [Destination] {
        config.visibleDestinations
    }

    var body: some View {
        NavigationStack {
            Group {
                // Keyed off *visible* destinations: when every destination is
                // hidden the list is indistinguishable from a fresh install.
                // Tapping the wordmark reveals them as usual.
                if visibleDestinations.isEmpty {
                    emptyState
                } else {
                    List(visibleDestinations) { destination in
                        NavigationLink(value: destination) {
                            DestinationRow(destination: destination, config: config)
                        }
                        .contextMenu {
                            Button("Remove Destination", role: .destructive) {
                                pendingDestinationRemoval = destination
                            }
                        }
                    }
                }
            }
            .navigationTitle("ShareMaster")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Destination.self) { destination in
                BucketBrowserView(destination: destination)
            }
            .toolbar {
                // The word mark doubles as the reveal switch for hidden
                // destinations (here and in Settings); deliberately gives no
                // visual hint.
                ToolbarItem(placement: .principal) {
                    Text("ShareMaster")
                        .font(.headline)
                        .onTapGesture {
                            withAnimation { config.revealHidden.toggle() }
                        }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Greyed out while every destination is concealed so the
                    // decoy empty state doesn't offer an upload picker.
                    UploadMenu(includeHidden: config.revealHidden)
                        .disabled(visibleDestinations.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                IOSSettingsView()
            }
            .alert(
                "Remove \"\(pendingDestinationRemoval?.name.isEmpty == false ? pendingDestinationRemoval!.name : "Untitled")\" destination?",
                isPresented: Binding(
                    get: { pendingDestinationRemoval != nil },
                    set: { if !$0 { pendingDestinationRemoval = nil } }
                )
            ) {
                Button("Remove Destination", role: .destructive) {
                    if let destination = pendingDestinationRemoval {
                        config.deleteDestination(id: destination.id)
                    }
                    pendingDestinationRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingDestinationRemoval = nil }
            } message: {
                Text("This only removes the destination from ShareMaster. It does not delete any files stored at the remote destination.")
            }
            .onChange(of: scenePhase) { _, phase in
                // Pick up config synced from the Mac via iCloud Keychain.
                if phase == .active {
                    config.refreshFromCloud()
                } else {
                    // Re-conceal hidden destinations whenever the app leaves
                    // the foreground (also keeps them out of the app switcher).
                    config.revealHidden = false
                }
            }
            .task {
                if scenePhase == .active {
                    config.refreshFromCloud()
                }
            }
        }
        // The status bars live in their own overlay window (StatusOverlay)
        // so they stay visible above sheets — e.g. a download started from
        // the file detail sheet. Attached here because the root view is the
        // first thing on screen once a window scene exists.
        .onAppear { StatusOverlay.shared.attach() }
        // Mobile-data alerts sit on the NavigationStack, not the root list:
        // transfers also start from pushed bucket browsers, and
        // presentations from a covered root view don't reliably appear.
        // Mobile-data gate: uploads attempted on cellular land in one of
        // these two alerts (see UploadManager.start).
        .alert(
            "Uploading on Mobile Data Is Disabled",
            isPresented: Binding(
                get: { uploads.showCellularDisabledAlert },
                set: { uploads.showCellularDisabledAlert = $0 }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("To upload over mobile data, turn on \"Upload on Mobile Data\" in Settings.")
        }
        .alert(
            "You're on Mobile Data",
            isPresented: Binding(
                get: { uploads.cellularPrompt != nil },
                set: { if !$0 { uploads.cancelCellularUpload() } }
            ),
            presenting: uploads.cellularPrompt
        ) { _ in
            Button("Continue") { uploads.confirmCellularUpload() }
            Button("Cancel", role: .cancel) { uploads.cancelCellularUpload() }
        } message: { prompt in
            Text(prompt.message)
        }
        // Downloads share the same gate settings (see DownloadManager.start).
        .alert(
            "Downloading on Mobile Data Is Disabled",
            isPresented: Binding(
                get: { downloads.showCellularDisabledAlert },
                set: { downloads.showCellularDisabledAlert = $0 }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("To download over mobile data, turn on \"Transfer on Mobile Data\" in Settings.")
        }
        .alert(
            "You're on Mobile Data",
            isPresented: Binding(
                get: { downloads.cellularPrompt != nil },
                set: { if !$0 { downloads.cancelCellularDownload() } }
            ),
            presenting: downloads.cellularPrompt
        ) { _ in
            Button("Continue") { downloads.confirmCellularDownload() }
            Button("Cancel", role: .cancel) { downloads.cancelCellularDownload() }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Destinations", systemImage: "tray.and.arrow.up")
        } description: {
            Text("Add an account and a destination to start sharing. The share extension uses the same configuration.")
        } actions: {
            Button("Open Settings") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct DestinationRow: View {
    let destination: Destination
    let config: ConfigStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: destination.isHidden ? "eye.slash" : "externaldrive.badge.icloud")
                .font(.title3)
                .foregroundStyle(destination.isHidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name.isEmpty ? destination.bucket : destination.name)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let account = config.account(id: destination.accountId)?.name ?? "?"
        let path = destination.pathPrefix.isEmpty ? "" : "/\(destination.pathPrefix.dropLast())"
        return "\(account) · \(destination.bucket)\(path)"
    }
}

#Preview {
    DestinationListView()
}
