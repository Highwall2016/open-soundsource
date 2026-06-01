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
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
