//
//  ShareMasterApp.swift
//  ShareMaster
//
//  Created by Conor Ryan on 02/07/26.
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
struct ShareMasterApp: App {
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
    static let statusItemDidReceiveDrop = Notification.Name("ShareMaster.statusItemDidReceiveDrop")

    /// Posted when an upload batch finishes and its confirmation has been shown.
    /// userInfo: ["success": Bool]
    static let uploadDidFinish = Notification.Name("ShareMaster.uploadDidFinish")
}

/// Transparent overlay on the status item button that accepts file drags.
/// Hovering a drag over the icon opens the popover so the user can drop on a
/// specific destination; dropping on the icon itself uploads to the current one.
final class StatusItemDragView: NSView {
    var onDragEntered: (() -> Void)?
    var onRightClick: (() -> Void)?

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
    // Control-click is treated as a right-click, matching macOS convention.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?()
        } else {
            (superview as? NSStatusBarButton)?.performClick(nil)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var modelContainer: ModelContainer?
    var popoverBackgroundView: PopoverBackgroundView?
    /// True while the popover is open because a drag hovered over the menu bar
    /// icon (rather than a click). Used to auto-close it once the upload ends.
    private var popoverOpenedByDrag = false
    private var popoverTeardown: DispatchWorkItem?
    
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
            applyMenuBarIcon()
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
            dragView.onRightClick = { [weak self] in
                self?.showStatusMenu()
            }
            button.addSubview(dragView)
        }

        // Refresh the status-item glyph whenever the preference changes.
        NotificationCenter.default.addObserver(
            forName: .menuBarIconStyleChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyMenuBarIcon()
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

        // SwiftUI context menus inside an NSPopover can occasionally leave a
        // transient popover active after the menu dismisses. Keep the user's
        // pin preference authoritative at the app boundary.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            guard ConfigStore.shared.pinPopover == false else { return }
            self?.popover?.performClose(nil)
        }
        
        // Setup popover. Content is built lazily on first open and torn down
        // shortly after close, so an idle ShareMaster holds no SwiftUI
        // hierarchy, thumbnails, or list state in memory.
        popover = NSPopover()
        popover?.behavior = .semitransient
        popover?.animates = true

        // Drop the selection highlight the instant the popover starts closing,
        // rather than waiting for didClose (which only fires after the close
        // animation finishes, leaving the pill lingering).
        NotificationCenter.default.addObserver(
            forName: NSPopover.willCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            self?.statusItem?.button?.highlight(false)
        }

        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            // Clear the drag flag so a later click-opened popover doesn't
            // auto-close after an unrelated upload.
            self?.popoverOpenedByDrag = false
            self?.schedulePopoverTeardown()
        }
    }

    private func makePopoverContentViewController() -> NSViewController {
        let contentView = ContentView()
            .modelContainer(modelContainer!)
            .environment(\.openSettingsAction, OpenSettingsAction { [weak self] in
                self?.openSettings()
            })
        let hosting = NSHostingController(rootView: contentView)
        // Let the popover track the SwiftUI content size, so it shrinks when
        // the recents section is collapsed and grows when it's expanded.
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
    }

    /// Frees the popover's SwiftUI hierarchy a minute after it closes. The
    /// delay keeps quick re-opens instant and avoids tearing down mid-upload
    /// UI (transfers themselves run in S3Service and are unaffected).
    private func schedulePopoverTeardown() {
        popoverTeardown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.popover?.isShown != true else { return }
            self.popover?.contentViewController = nil
            self.popoverBackgroundView = nil
        }
        popoverTeardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }
    
    /// Applies the user's chosen glyph to the status item as a template image
    /// (renders white/black to match the menu bar). Falls back to an SF Symbol
    /// if the asset is somehow missing.
    private func applyMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        let style = ConfigStore.shared.menuBarIconStyle
        let icon = NSImage(named: style.assetName)
            ?? NSImage(systemSymbolName: "paperplane", accessibilityDescription: "ShareMaster")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 22, height: 22)
        icon?.accessibilityDescription = "ShareMaster"
        button.image = icon
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

        ConfigStore.shared.refreshFromCloud()

        popoverTeardown?.cancel()
        if popover.contentViewController == nil {
            popover.contentViewController = makePopoverContentViewController()
        }

        // Pinned popovers survive focus changes; unpinned ones close as soon
        // as the user interacts with anything else.
        popover.behavior = ConfigStore.shared.pinPopover ? .semitransient : .transient

        // Follow the system Light/Dark setting. Without this the popover
        // inherits the dark/vibrant appearance of the menu-bar button it's
        // anchored to and renders dark even in Light Mode.
        popover.appearance = NSApp.effectiveAppearance

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // Show the standard rounded selection background behind the icon while
        // the popover is open, matching every other menu-bar item. Deferred to
        // the next runloop tick: the click reaches us via the drag view's
        // performClick(_:), which highlights and then *un*-highlights the button
        // as it returns — setting it synchronously here would be wiped, so we
        // run just after that reset to make the highlight stick.
        DispatchQueue.main.async { [weak button] in
            button?.highlight(true)
        }

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
    
    /// Prepares for the native SwiftUI Settings scene to open: the caller
    /// (a SwiftUI view) invokes `@Environment(\.openSettings)` right after.
    func openSettings() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Right-click / control-click menu on the status item: Settings and Quit.
    ///
    /// Presented by assigning `statusItem.menu` and clicking, rather than
    /// `NSMenu.popUp(in:)`. A menu popped up anchored to the status button
    /// inherits the *menu bar's* dark/vibrant appearance and renders dark even
    /// in Light Mode; the system-presented status menu uses the correct system
    /// appearance (and draws the selection highlight for us). The menu is
    /// detached again in `menuDidClose` so left-click still opens the popover.
    private func showStatusMenu() {
        guard let statusItem = statusItem else { return }
        popover?.performClose(nil)

        let menu = NSMenu()
        menu.delegate = self
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        // A nil target lets the standard Quit travel up to NSApp.
        menu.addItem(NSMenuItem(
            title: "Quit ShareMaster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so a later left-click opens the popover instead of the menu.
        statusItem?.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI's Settings scene is opened through this AppKit action; the
        // selector was renamed from Preferences in macOS 13, so fall back for
        // safety.
        if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
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
