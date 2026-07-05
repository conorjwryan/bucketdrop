//
//  UploadManager.swift
//  ShareMasterIOS
//
//  App-wide upload state. Uploads run here rather than inside a modal sheet
//  so the user can keep browsing (or leave the app) while they finish; the
//  UploadStatusBar at the bottom of the root view reflects this state.
//  Batches queue and run one at a time. A UIKit background task keeps
//  transfers alive for the grace period iOS grants after backgrounding.
//

import SwiftUI
import UIKit
import Network

/// Tracks whether the active network path runs over cellular, for the
/// mobile-data gate below. NWPathMonitor delivers updates asynchronously,
/// so the very first transfer after launch could race the initial reading —
/// acceptable for a warning heuristic.
@MainActor @Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private(set) var isOnCellular = false
    /// Whether any usable network path exists. Starts optimistic so the very
    /// first listing after launch isn't misreported as offline before the
    /// monitor's first callback lands.
    private(set) var isConnected = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let cellular = path.status == .satisfied && path.usesInterfaceType(.cellular)
            let connected = path.status == .satisfied
            Task { @MainActor in
                NetworkMonitor.shared.isOnCellular = cellular
                NetworkMonitor.shared.isConnected = connected
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.cjwr.ShareMaster.NetworkMonitor"))
    }
}

@MainActor @Observable
final class UploadManager {
    static let shared = UploadManager()

    enum Phase: Equatable {
        case uploading(destinationName: String)
        case done(fileCount: Int, copied: Bool)
        case failed(String)
    }

    /// nil when there's nothing to show in the status bar.
    private(set) var phase: Phase?
    /// Overall progress of the current batch, 0...1.
    private(set) var progress: Double = 0

    private struct Batch {
        let files: [URL]
        let destinationName: String
        let s3Config: S3Config
        /// Overrides the destination's path prefix (folder open in the
        /// browser); nil uploads to the destination's configured prefix.
        let keyPrefix: String?
        let copyOnUpload: Bool
        let onUploaded: () -> Void
    }

    private var queue: [Batch] = []
    private var isRunning = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var clearTask: Task<Void, Never>?

    // MARK: Mobile-data gate

    /// A batch held back pending the "you're on mobile data" confirmation.
    struct CellularPrompt: Identifiable {
        let id = UUID()
        let files: [URL]
        let destination: Destination
        let keyPrefix: String?
        let onUploaded: () -> Void
        let totalBytes: Int64

        var message: String {
            let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return files.count == 1
                ? "You're on mobile data. Uploading this file will use about \(size) of your mobile data plan."
                : "You're on mobile data. Uploading these \(files.count) files will use about \(size) of your mobile data plan."
        }
    }

    /// Non-nil while waiting for the user to confirm a cellular upload.
    private(set) var cellularPrompt: CellularPrompt?
    /// Set when an upload was refused because mobile data is disabled.
    var showCellularDisabledAlert = false

    private init() {
        // Warm the path monitor now (UploadManager.shared is touched at app
        // launch by DestinationListView). NWPathMonitor's first reading is
        // asynchronous — starting it lazily at gate-check time would always
        // read "not cellular" and wave the first upload through.
        _ = NetworkMonitor.shared
    }

    func start(files: [URL], destination: Destination, keyPrefix: String? = nil, onUploaded: @escaping () -> Void = {}) {
        if NetworkMonitor.shared.isOnCellular {
            let config = ConfigStore.shared
            if !config.allowsCellularUploads {
                presentAfterSheetDismissal { self.showCellularDisabledAlert = true }
                return
            }
            if !config.suppressCellularWarnings {
                let prompt = CellularPrompt(
                    files: files,
                    destination: destination,
                    keyPrefix: keyPrefix,
                    onUploaded: onUploaded,
                    totalBytes: files.reduce(0) { $0 + Self.fileSize($1) }
                )
                presentAfterSheetDismissal { self.cellularPrompt = prompt }
                return
            }
        }
        enqueue(files: files, destination: destination, keyPrefix: keyPrefix, onUploaded: onUploaded)
    }

    /// start() is called from inside a picker or destination sheet that is
    /// dismissing at that very moment. The gate alerts live on the root
    /// view, and flipping their state mid-dismissal asks SwiftUI to present
    /// over the outgoing sheet — UIKit drops that silently and never
    /// retries. Deferring past the dismissal animation lets the alert land
    /// on the uncovered root view.
    private func presentAfterSheetDismissal(_ present: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            present()
        }
    }

    func confirmCellularUpload() {
        guard let prompt = cellularPrompt else { return }
        cellularPrompt = nil
        enqueue(files: prompt.files, destination: prompt.destination, keyPrefix: prompt.keyPrefix, onUploaded: prompt.onUploaded)
    }

    func cancelCellularUpload() {
        cellularPrompt = nil
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func enqueue(files: [URL], destination: Destination, keyPrefix: String?, onUploaded: @escaping () -> Void) {
        guard let s3Config = ConfigStore.shared.s3Config(for: destination) else {
            phase = .failed("This destination's account is missing its credentials.")
            return
        }
        ConfigStore.shared.lastSelectedDestinationID = destination.id
        queue.append(Batch(
            files: files,
            destinationName: Self.displayName(destination: destination, keyPrefix: keyPrefix, configuredPrefix: s3Config.pathPrefix),
            s3Config: s3Config,
            keyPrefix: keyPrefix,
            copyOnUpload: s3Config.copyOnUpload,
            onUploaded: onUploaded
        ))
        runIfNeeded()
    }

    /// Status-bar label for where a batch is going. The destination's name
    /// covers its configured prefix; a browsed-to folder shows its own name
    /// (or the bucket for the root) so the bar matches where files land.
    private static func displayName(destination: Destination, keyPrefix: String?, configuredPrefix: String) -> String {
        let destinationName = destination.name.isEmpty ? destination.bucket : destination.name
        guard let keyPrefix, keyPrefix != configuredPrefix else { return destinationName }
        guard !keyPrefix.isEmpty else { return destination.bucket }
        let folder = (String(keyPrefix.dropLast()) as NSString).lastPathComponent
        return "\(destination.bucket)/\(folder)"
    }

    /// Dismisses a lingering done/failed bar (uploading can't be dismissed).
    func clearStatus() {
        guard !isRunning else { return }
        clearTask?.cancel()
        clearTask = nil
        phase = nil
    }

    private func runIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        clearTask?.cancel()
        clearTask = nil
        beginBackgroundTask()
        Task {
            while !queue.isEmpty {
                await run(queue.removeFirst())
            }
            isRunning = false
            endBackgroundTask()
        }
    }

    private func run(_ batch: Batch) async {
        progress = 0
        phase = .uploading(destinationName: batch.destinationName)
        do {
            var links: [String] = []
            for (index, file) in batch.files.enumerated() {
                let result = try await S3Service.shared.upload(fileURL: file, config: batch.s3Config, keyPrefix: batch.keyPrefix) { fileProgress in
                    Task { @MainActor in
                        self.progress = (Double(index) + fileProgress) / Double(batch.files.count)
                    }
                }
                links.append(result.url)
            }
            if batch.copyOnUpload {
                UIPasteboard.general.string = links.joined(separator: "\n")
            }
            phase = .done(fileCount: links.count, copied: batch.copyOnUpload)
            batch.onUploaded()
            scheduleClear()
        } catch {
            // Backstop for the pre-flight gate: if the OS refused the
            // transfer because cellular is disallowed, show the same
            // "disabled" alert instead of a raw network error.
            if !ConfigStore.shared.allowsCellularUploads,
               NetworkMonitor.shared.isOnCellular,
               let urlError = error as? URLError,
               [.dataNotAllowed, .notConnectedToInternet, .internationalRoamingOff].contains(urlError.code) {
                phase = nil
                showCellularDisabledAlert = true
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, case .done = phase else { return }
            phase = nil
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ShareMaster Upload") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// Floating bar pinned above the bottom safe area while an upload is in
/// flight, then briefly confirming completion.
struct UploadStatusBar: View {
    @State private var manager = UploadManager.shared

    var body: some View {
        Group {
            if let phase = manager.phase {
                HStack(spacing: 12) {
                    switch phase {
                    case .uploading(let destinationName):
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Uploading to \(destinationName)…")
                                .font(.subheadline)
                                .lineLimit(1)
                            ProgressView(value: manager.progress)
                                .progressViewStyle(.linear)
                        }
                    case .done(let fileCount, let copied):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(doneMessage(fileCount: fileCount, copied: copied))
                            .font(.subheadline)
                        Spacer(minLength: 0)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.icloud.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.subheadline)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Button {
                            manager.clearStatus()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: manager.phase)
    }

    private func doneMessage(fileCount: Int, copied: Bool) -> String {
        if copied {
            return fileCount == 1
                ? "File uploaded and link copied to clipboard"
                : "\(fileCount) files uploaded and links copied to clipboard"
        }
        return fileCount == 1
            ? "File uploaded"
            : "\(fileCount) files uploaded"
    }
}
