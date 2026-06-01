/// process-tap — capture a specific app's audio and display a live VU meter.
///
/// Usage:
///   swift run process-tap --bundle-id com.google.Chrome
///   swift run process-tap --pid 12345
///
/// Requires macOS 14.2+.
///
/// PERMISSIONS:
///   First run will prompt for Microphone permission.
///   If no prompt appears, go to:
///     System Settings → Privacy & Security → Microphone
///     → enable Terminal (or iTerm2 / the app you're running from)

import CoreAudio
import AVFoundation
import AppKit
import Foundation

// ── Argument parsing ──────────────────────────────────────────────────────────

func printUsage() {
    print("""

  process-tap — live VU meter for a specific app's audio output

  Usage:
    swift run process-tap --bundle-id <bundleID>   e.g. com.google.Chrome
    swift run process-tap --pid <pid>              e.g. 12345

  Tip: run  swift run list-apps  first to see active audio processes.

""")
}

let args = CommandLine.arguments
guard args.count == 3 else { printUsage(); exit(1) }

let flag  = args[1]
let value = args[2]

// ── Availability guard ────────────────────────────────────────────────────────

guard #available(macOS 14.2, *) else {
    fputs("❌  process-tap requires macOS 14.2 or later.\n", stderr)
    exit(1)
}

// ── Resolve PID ───────────────────────────────────────────────────────────────

var targetPID: pid_t = -1
var targetName = value

if flag == "--bundle-id" {
    let bundleID = value
    let runningApps = NSWorkspace.shared.runningApplications
    guard let app = runningApps.first(where: { $0.bundleIdentifier == bundleID }) else {
        fputs("❌  No running app with bundle ID: \(bundleID)\n", stderr)
        fputs("   Run  swift run list-apps  to see active audio processes.\n", stderr)
        exit(1)
    }
    targetPID  = app.processIdentifier
    targetName = app.localizedName ?? bundleID
    print("✓  Found '\(targetName)'  (PID \(targetPID))")

} else if flag == "--pid" {
    guard let pid = Int32(value) else {
        fputs("❌  Invalid PID: \(value)\n", stderr)
        exit(1)
    }
    targetPID = pid
    // Try to resolve a friendly name
    if let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == pid }) {
        targetName = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"
    }
    print("✓  Targeting PID \(targetPID)  (\(targetName))")

} else {
    fputs("❌  Unknown flag: \(flag)\n", stderr)
    printUsage()
    exit(1)
}

// ── Create process tap ────────────────────────────────────────────────────────

let tapManager = ProcessTapManager()
let tapID: AudioObjectID

do {
    tapID = try tapManager.createTap(pid: targetPID)
    print("✓  Process tap created  (object ID \(tapID))")
} catch {
    fputs("❌  \(error.localizedDescription)\n", stderr)
    exit(1)
}

// ── Create aggregate device ───────────────────────────────────────────────────

let aggManager = AggregateDeviceManager()
let aggDeviceID: AudioDeviceID

do {
    let tapUID = try tapManager.tapUID(for: tapID)
    aggDeviceID = try aggManager.createDevice(tapUID: tapUID)
    print("✓  Aggregate device created  (device ID \(aggDeviceID))")
} catch {
    fputs("❌  \(error.localizedDescription)\n", stderr)
    tapManager.destroyTap(tapID)
    exit(1)
}

// ── Resolve sample rate ───────────────────────────────────────────────────────

let sampleRate: Double
do {
    sampleRate = try aggManager.sampleRate(for: aggDeviceID)
    print("✓  Sample rate: \(Int(sampleRate)) Hz")
} catch {
    // Fall back to 48 kHz — most common on macOS
    sampleRate = 48_000
    print("⚠️  Could not query sample rate, defaulting to 48000 Hz")
}

// ── Configure and start AVAudioEngine ────────────────────────────────────────

let captureEngine = AudioCaptureEngine()
let vuMeter       = VUMeter()

captureEngine.onRMS = { left, right in
    DispatchQueue.main.async {
        vuMeter.update(leftRMS: left, rightRMS: right)
    }
}

do {
    try captureEngine.configure(aggDeviceID: aggDeviceID, sampleRate: sampleRate)
    try captureEngine.start()
    print("✓  Audio engine running\n")
} catch {
    fputs("❌  \(error.localizedDescription)\n", stderr)
    aggManager.destroyDevice()
    tapManager.destroyTap(tapID)
    exit(1)
}

// ── VU meter refresh timer (~20 fps) ─────────────────────────────────────────

print(String(repeating: " ", count: 70))   // pre-allocate lines for VU meter
print(String(repeating: " ", count: 70))
print(String(repeating: " ", count: 70))
print(String(repeating: " ", count: 70))
print(String(repeating: " ", count: 70))
print(String(repeating: " ", count: 70))

let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    vuMeter.render(appName: targetName, pid: targetPID)
}
RunLoop.main.add(timer, forMode: .common)

// ── Wait for Enter ────────────────────────────────────────────────────────────

// Run the main loop until Enter is pressed.
// We spin the RunLoop manually so the timer fires while we wait.
let stdinHandle = FileHandle.standardInput
stdinHandle.waitForDataInBackgroundAndNotify()

NotificationCenter.default.addObserver(
    forName: .NSFileHandleDataAvailable,
    object: stdinHandle,
    queue: .main
) { _ in
    // Enter pressed → clean up and exit
    timer.invalidate()
    captureEngine.stop()
    aggManager.destroyDevice()
    tapManager.destroyTap(tapID)
    print("\n✓  Stopped — resources cleaned up.\n")
    exit(0)
}

RunLoop.main.run()
