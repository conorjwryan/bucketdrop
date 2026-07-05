//
//  DownloadManager.swift
//  ShareMasterIOS
//
//  App-wide download state, mirroring UploadManager: jobs queue and run
//  one at a time so the user can keep browsing; the DownloadStatusBar at
//  the bottom of the root view reflects this state. Completed files are
//  handed to DownloadStore for offline viewing. Downloads share the
//  uploads' mobile-data gate (same settings, same alert flow).
//

import SwiftUI
import UIKit

@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()

    enum Phase: Equatable {
        case downloading(filename: String)
        case done(filename: String)
        case failed(String)
    }

    /// nil when there's nothing to show in the status bar.
    private(set) var phase: Phase?
    /// Progress of the current download, 0...1.
    private(set) var progress: Double = 0
    /// Keys currently queued or downloading, so rows can show a spinner
    /// instead of offering a second download.
    private(set) var activeKeys: Set<String> = []

    private struct Job {
        let object: S3Object
        let destination: Destination
        let s3Config: S3Config
    }

    private var queue: [Job] = []
    private var isRunning = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var clearTask: Task<Void, Never>?

    // MARK: Mobile-data gate (same settings as uploads)

    /// A download held back pending the "you're on mobile data" confirmation.
    struct CellularPrompt: Identifiable {
        let id = UUID()
        let object: S3Object
        let destination: Destination

        var message: String {
            let size = ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file)
            return "You're on mobile data. Downloading this file will use about \(size) of your mobile data plan."
        }
    }

    /// Non-nil while waiting for the user to confirm a cellular download.
    private(set) var cellularPrompt: CellularPrompt?
    /// Set when a download was refused because mobile data is disabled.
    var showCellularDisabledAlert = false

    private init() {}

    func isActive(_ object: S3Object) -> Bool {
        activeKeys.contains(object.key)
    }

    func start(object: S3Object, destination: Destination) {
        guard !isActive(object) else { return }
        if NetworkMonitor.shared.isOnCellular {
            let config = ConfigStore.shared
            if !config.allowsCellularUploads {
                presentAfterSheetDismissal { self.showCellularDisabledAlert = true }
                return
            }
            if !config.suppressCellularWarnings {
                let prompt = CellularPrompt(object: object, destination: destination)
                presentAfterSheetDismissal { self.cellularPrompt = prompt }
                return
            }
        }
        enqueue(object: object, destination: destination)
    }

    /// Same deferral as UploadManager.presentAfterSheetDismissal: downloads
    /// start from context menus and the detail sheet, and flipping alert
    /// state mid-dismissal gets dropped silently by UIKit.
    private func presentAfterSheetDismissal(_ present: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            present()
        }
    }

    func confirmCellularDownload() {
        guard let prompt = cellularPrompt else { return }
        cellularPrompt = nil
        enqueue(object: prompt.object, destination: prompt.destination)
    }

    func cancelCellularDownload() {
        cellularPrompt = nil
    }

    private func enqueue(object: S3Object, destination: Destination) {
        guard let s3Config = ConfigStore.shared.s3Config(for: destination) else {
            phase = .failed("This destination's account is missing its credentials.")
            return
        }
        activeKeys.insert(object.key)
        queue.append(Job(object: object, destination: destination, s3Config: s3Config))
        runIfNeeded()
    }

    /// Dismisses a lingering done/failed bar (downloading can't be dismissed).
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

    private func run(_ job: Job) async {
        progress = 0
        phase = .downloading(filename: job.object.filename)
        defer { activeKeys.remove(job.object.key) }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent((job.object.key as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(
                at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let savedURL = try await S3Service.shared.download(
                key: job.object.key, to: tempURL, config: job.s3Config, overwrite: true
            ) { fileProgress in
                Task { @MainActor in
                    self.progress = fileProgress
                }
            }
            try DownloadStore.shared.record(
                tempURL: savedURL, object: job.object, destination: job.destination
            )
            phase = .done(filename: job.object.filename)
            scheduleClear()
        } catch {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
            // Backstop for the pre-flight gate, as in UploadManager.run().
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
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ShareMaster Download") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// Floating bar pinned above the bottom safe area while a download is in
/// flight, then briefly confirming completion. Stacks with UploadStatusBar
/// (both visible at once is rare and harmless).
struct DownloadStatusBar: View {
    @State private var manager = DownloadManager.shared

    var body: some View {
        Group {
            if let phase = manager.phase {
                HStack(spacing: 12) {
                    switch phase {
                    case .downloading(let filename):
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Downloading \(filename)…")
                                .font(.subheadline)
                                .lineLimit(1)
                            ProgressView(value: manager.progress)
                                .progressViewStyle(.linear)
                        }
                    case .done(let filename):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(filename) downloaded")
                            .font(.subheadline)
                            .lineLimit(1)
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
}
