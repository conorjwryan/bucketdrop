//
//  BucketDropApp.swift
//  BucketDrop
//
//  Created by Fayaz Ahmed Aralikatti on 12/01/26.
//

import SwiftUI
import SwiftData
import AppKit

// MARK: - Popover Background View
class PopoverBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.set()
        dirtyRect.fill()
    }
}

@main
struct BucketDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([UploadedFile.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
        .modelContainer(sharedModelContainer)
    }
}

extension Notification.Name {
    /// Posted when files are dropped directly on the menu bar icon.
    /// userInfo: ["urls": [URL]]
    static let statusItemDidReceiveDrop = Notification.Name("BucketDrop.statusItemDidReceiveDrop")

    /// Posted when an upload batch finishes and its confirmation has been shown.
    /// userInfo: ["success": Bool]
    static let uploadDidFinish = Notification.Name("BucketDrop.uploadDidFinish")
}

/// Transparent overlay on the status item button that accepts file drags.
/// Hovering a drag over the icon opens the popover so the user can drop on a
/// specific destination; dropping on the icon itself uploads to the current one.
final class StatusItemDragView: NSView {
    var onDragEntered: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?()
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return false }
        NotificationCenter.default.post(name: .statusItemDidReceiveDrop, object: nil, userInfo: ["urls": urls])
        return true
    }

    // This view sits on top of the status bar button, so forward clicks to it.
    override func mouseDown(with event: NSEvent) {
        (superview as? NSStatusBarButton)?.performClick(nil)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var modelContainer: ModelContainer?
    var settingsWindow: NSWindow?
    var popoverBackgroundView: PopoverBackgroundView?
    /// True while the popover is open because a drag hovered over the menu bar
    /// icon (rather than a click). Used to auto-close it once the upload ends.
    private var popoverOpenedByDrag = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
        
        // Setup model container
        let schema = Schema([UploadedFile.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        modelContainer = try? ModelContainer(for: schema, configurations: [modelConfiguration])
        
        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "BucketDrop")
            button.action = #selector(togglePopover)
            button.target = self

            // Accept file drags on the icon: hovering opens the popover,
            // dropping uploads to the currently selected destination.
            let dragView = StatusItemDragView(frame: button.bounds)
            dragView.autoresizingMask = [.width, .height]
            dragView.onDragEntered = { [weak self] in
                guard let self else { return }
                if self.popover?.isShown != true {
                    self.popoverOpenedByDrag = true
                    self.showPopover()
                }
            }
            button.addSubview(dragView)
        }

        // Close a drag-opened popover once the upload has finished (and its
        // confirmation has been shown), so it doesn't linger.
        NotificationCenter.default.addObserver(
            forName: .uploadDidFinish, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.popoverOpenedByDrag else { return }
            let success = note.userInfo?["success"] as? Bool ?? true
            if success {
                self.popover?.performClose(nil)
            }
            self.popoverOpenedByDrag = false
        }
        
        // Setup popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 560, height: 460)
        popover?.behavior = .semitransient
        popover?.animates = true
        
        let contentView = ContentView()
            .modelContainer(modelContainer!)
            .environment(\.openSettingsAction, OpenSettingsAction { [weak self] in
                self?.openSettings()
            })
        popover?.contentViewController = NSHostingController(rootView: contentView)

        // If a drag-opened popover is dismissed some other way (click outside,
        // drag abandoned), clear the flag so a later click-opened popover
        // doesn't auto-close after an unrelated upload.
        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            self?.popoverOpenedByDrag = false
        }
    }
    
    @objc func togglePopover() {
        guard let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverOpenedByDrag = false
            showPopover()
        }
    }

    func showPopover() {
        guard let popover = popover, let button = statusItem?.button, !popover.isShown else { return }

        // Pinned popovers survive focus changes; unpinned ones close as soon
        // as the user interacts with anything else.
        popover.behavior = ConfigStore.shared.pinPopover ? .semitransient : .transient

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // Add solid white background to popover (including the arrow/notch)
        if let contentView = popover.contentViewController?.view,
           let frameView = contentView.window?.contentView?.superview {
            // Check if background view already exists
            if popoverBackgroundView == nil || popoverBackgroundView?.superview == nil {
                let bgView = PopoverBackgroundView(frame: frameView.bounds)
                bgView.autoresizingMask = [.width, .height]
                frameView.addSubview(bgView, positioned: .below, relativeTo: frameView)
                popoverBackgroundView = bgView
            }
        }
    }
    
    func openSettings() {
        // Close popover first
        popover?.performClose(nil)
        
        // Check if settings window already exists
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create settings window
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "BucketDrop Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        
        // Center the window on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowSize = window.frame.size
            let x = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
            let y = screenFrame.origin.y + (screenFrame.height - windowSize.height) / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        settingsWindow = window
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// Custom environment key for opening settings
struct OpenSettingsAction {
    let action: () -> Void
    
    func callAsFunction() {
        action()
    }
}

struct OpenSettingsActionKey: EnvironmentKey {
    static let defaultValue = OpenSettingsAction { }
}

extension EnvironmentValues {
    var openSettingsAction: OpenSettingsAction {
        get { self[OpenSettingsActionKey.self] }
        set { self[OpenSettingsActionKey.self] = newValue }
    }
}
