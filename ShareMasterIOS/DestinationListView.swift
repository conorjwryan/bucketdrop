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
    @State private var showHidden = false

    private var visibleDestinations: [Destination] {
        config.sortedDestinations.filter { showHidden || !$0.isHidden }
    }

    var body: some View {
        NavigationStack {
            Group {
                if config.destinations.isEmpty {
                    emptyState
                } else {
                    List(visibleDestinations) { destination in
                        NavigationLink(value: destination) {
                            DestinationRow(destination: destination, config: config)
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
                // destinations; deliberately gives no visual hint.
                ToolbarItem(placement: .principal) {
                    Text("ShareMaster")
                        .font(.headline)
                        .onTapGesture {
                            withAnimation { showHidden.toggle() }
                        }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    UploadMenu(includeHidden: showHidden)
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
            .safeAreaInset(edge: .bottom) {
                UploadStatusBar()
            }
            .onChange(of: scenePhase) { _, phase in
                // Pick up config synced from the Mac via iCloud Keychain.
                if phase == .active {
                    config.refreshFromCloud()
                } else {
                    // Re-conceal hidden destinations whenever the app leaves
                    // the foreground (also keeps them out of the app switcher).
                    showHidden = false
                }
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
