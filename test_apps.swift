import AppKit
let apps = NSWorkspace.shared.runningApplications
for app in apps {
    if let name = app.localizedName, name.contains("Chrome") {
        print("\(name) - \(app.bundleIdentifier ?? "nil") - \(app.processIdentifier)")
    }
}
