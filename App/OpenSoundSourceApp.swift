import SwiftUI
import AppKit

@main
struct OpenSoundSourceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var audioManager = AudioManager()

    var body: some Scene {
        // Main visible window
        WindowGroup {
            AppListView()
                .environmentObject(audioManager)
                .frame(minWidth: 380, minHeight: 480)
                .onAppear { appDelegate.audioManager = audioManager }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    weak var audioManager: AudioManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request screen capture permissions required for process tapping
        // Only prompt once; after that the app is already in System Settings
        if !CGPreflightScreenCaptureAccess() {
            let key = "hasRequestedScreenCaptureAccess"
            if !UserDefaults.standard.bool(forKey: key) {
                CGRequestScreenCaptureAccess()
                UserDefaults.standard.set(true, forKey: key)
            }
        }

        // Create menu bar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if let img = NSImage(named: "menu_bar") {
                // Ensure it adapts to light/dark mode by treating it as a template
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "🔊"
            }
            button.action = #selector(menuBarClicked)
            button.target = self
        }
    }
    
    @objc func menuBarClicked() {
        // Bring the main window to front
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioManager?.stopAllRouting()
    }
}
