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

@MainActor @Observable
final class UploadManager {
    static let shared = UploadManager()

    enum Phase: Equatable {
        case uploading(destinationName: String)
        case done(fileCount: Int)
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
        let onUploaded: () -> Void
    }

    private var queue: [Batch] = []
    private var isRunning = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var clearTask: Task<Void, Never>?

    private init() {}

    func start(files: [URL], destination: Destination, onUploaded: @escaping () -> Void = {}) {
        guard let s3Config = ConfigStore.shared.s3Config(for: destination) else {
            phase = .failed("This destination's account is missing its credentials.")
            return
        }
        ConfigStore.shared.lastSelectedDestinationID = destination.id
        queue.append(Batch(
            files: files,
            destinationName: destination.name.isEmpty ? destination.bucket : destination.name,
            s3Config: s3Config,
            onUploaded: onUploaded
        ))
        runIfNeeded()
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
                let result = try await S3Service.shared.upload(fileURL: file, config: batch.s3Config) { fileProgress in
                    Task { @MainActor in
                        self.progress = (Double(index) + fileProgress) / Double(batch.files.count)
                    }
                }
                links.append(result.url)
            }
            UIPasteboard.general.string = links.joined(separator: "\n")
            phase = .done(fileCount: links.count)
            batch.onUploaded()
            scheduleClear()
        } catch {
            phase = .failed(error.localizedDescription)
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
/// flight, then briefly confirming the links landed on the clipboard.
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
                    case .done(let fileCount):
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(fileCount == 1
                             ? "File uploaded and link copied to clipboard"
                             : "\(fileCount) files uploaded and links copied to clipboard")
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
}
