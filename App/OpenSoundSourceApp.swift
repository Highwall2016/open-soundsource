import SwiftUI
import AppKit
import Combine

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var audioManager: AudioManager!
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AudioManager is @MainActor — safe to init here (called on main thread)
        self.audioManager = AudioManager()

        // Request screen capture permissions required for process tapping
        if !CGPreflightScreenCaptureAccess() {
            let key = "hasRequestedScreenCaptureAccess"
            if !UserDefaults.standard.bool(forKey: key) {
                CGRequestScreenCaptureAccess()
                UserDefaults.standard.set(true, forKey: key)
            }
        }

        // Configure popover with SwiftUI content
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let hostingController = NSHostingController(
            rootView: PopoverContentView()
                .environmentObject(audioManager)
        )
        popover.contentViewController = hostingController

        // Create menu bar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            updateStatusIcon()
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Observe routing state changes to update the icon
        audioManager.$apps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        // Close any lingering main windows (no window UI in menu bar mode)
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                window.close()
            }
        }
    }

    // MARK: - Status Bar Actions

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSView) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Refresh apps each time the popover opens
            audioManager.refreshApps()
            audioManager.refreshOutputDevices()

            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)

            // Install global click monitor to dismiss popover
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }

    private func showContextMenu(_ sender: NSView) {
        let menu = NSMenu()

        menu.addItem(withTitle: "Refresh",
                     action: #selector(refreshClicked),
                     keyEquivalent: "r").target = self

        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit OpenSoundSource",
                     action: #selector(quitClicked),
                     keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Remove menu after it closes so left-click still triggers action
        statusItem.menu = nil
    }

    @objc private func refreshClicked() {
        audioManager.refreshOutputDevices()
        audioManager.refreshApps()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    // MARK: - Status Icon

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let hasActiveRouting = audioManager.apps.contains { app in
            if case .active = app.routingState { return true }
            return false
        }

        let symbolName = hasActiveRouting
            ? "speaker.wave.3.fill"
            : "speaker.wave.2"

        if let img = NSImage(systemSymbolName: symbolName,
                             accessibilityDescription: "OpenSoundSource") {
            img.isTemplate = true
            button.image = img
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Lifecycle

    func applicationWillTerminate(_ notification: Notification) {
        audioManager.stopAllRouting()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let button = statusItem.button {
            togglePopover(button)
        }
        return false
    }
}

// MARK: - Popover Content View

/// Wraps AppListView with a fixed frame suitable for the popover.
private struct PopoverContentView: View {
    @EnvironmentObject var audioManager: AudioManager

    var body: some View {
        AppListView()
            .frame(width: 380, height: 480)
    }
}
