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
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if config.destinations.isEmpty {
                    emptyState
                } else {
                    List(config.sortedDestinations) { destination in
                        NavigationLink(value: destination) {
                            DestinationRow(destination: destination, config: config)
                        }
                    }
                }
            }
            .navigationTitle("ShareMaster")
            .navigationDestination(for: Destination.self) { destination in
                BucketBrowserView(destination: destination)
            }
            .toolbar {
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
            .onChange(of: scenePhase) { _, phase in
                // Pick up config synced from the Mac via iCloud Keychain.
                if phase == .active { config.refreshFromCloud() }
            }
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
            Image(systemName: "externaldrive.badge.icloud")
                .font(.title3)
                .foregroundStyle(.tint)
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
