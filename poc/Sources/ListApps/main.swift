/// list-apps — list running applications that are currently playing audio.
///
/// Usage:  swift run list-apps
///
/// Uses kAudioHardwarePropertyProcessObjectList (macOS 14+) to enumerate
/// audio process objects, then cross-references with NSRunningApplication
/// to resolve bundle IDs → human-readable names.
///
/// No special entitlements required (read-only metadata query).

import CoreAudio
import AppKit
import Foundation

// ── CoreAudio HAL helpers ────────────────────────────────────────────────────

func getPropertyObjectIDs(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope:    scope,
        mElement:  kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func getPropertyUInt32(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> UInt32? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope:    scope,
        mElement:  kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

func getPropertyString(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope:    scope,
        mElement:  kAudioObjectPropertyElementMain
    )
    var value: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    guard status == noErr, let result = value else { return nil }
    return result as String
}

// ── Audio process info ────────────────────────────────────────────────────────

struct AudioProcessInfo {
    let processObjectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let appName: String?
    let isRunningOutput: Bool
    let isRunningInput: Bool
}

// ── Main ─────────────────────────────────────────────────────────────────────

let system = AudioObjectID(kAudioObjectSystemObject)

// Build a PID → NSRunningApplication lookup table
let runningApps = NSWorkspace.shared.runningApplications
var appsByPID: [pid_t: NSRunningApplication] = [:]
for app in runningApps { appsByPID[app.processIdentifier] = app }

// Enumerate audio process objects (macOS 14+)
let processObjectIDs = getPropertyObjectIDs(system, selector: kAudioHardwarePropertyProcessObjectList)

var audioApps: [AudioProcessInfo] = []

for procObjID in processObjectIDs {
    // PID
    guard let pid = getPropertyUInt32(procObjID, selector: kAudioProcessPropertyPID).map({ pid_t($0) }) else {
        continue
    }

    // Bundle ID (may be empty for system processes)
    let bundleID = getPropertyString(procObjID, selector: kAudioProcessPropertyBundleID)

    // Is this process currently outputting audio?
    let isRunningOutput = (getPropertyUInt32(procObjID, selector: kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
    let isRunningInput  = (getPropertyUInt32(procObjID, selector: kAudioProcessPropertyIsRunningInput)  ?? 0) != 0

    let appName = appsByPID[pid]?.localizedName

    audioApps.append(AudioProcessInfo(
        processObjectID: procObjID,
        pid:             pid,
        bundleID:        bundleID,
        appName:         appName,
        isRunningOutput: isRunningOutput,
        isRunningInput:  isRunningInput
    ))
}

// Sort: active output first, then by name
audioApps.sort {
    if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }
    let a = $0.appName ?? $0.bundleID ?? ""
    let b = $1.appName ?? $1.bundleID ?? ""
    return a < b
}

// ── Display ──────────────────────────────────────────────────────────────────

print()
print("🎵 Audio Process List  (\(audioApps.count) audio process objects registered)")
print(String(repeating: "─", count: 72))
print(String(
    format: "  %-28@  %-6@  %-8@  %-8@  %-36@",
    "App Name" as NSString, "PID" as NSString, "Output" as NSString, "Input" as NSString, "Bundle ID" as NSString
))
print(String(repeating: "─", count: 72))

for info in audioApps {
    let name    = info.appName   ?? "(system / no name)"
    let bundle  = info.bundleID  ?? "—"
    let outMark = info.isRunningOutput ? "▶ playing" : "—"
    let inMark  = info.isRunningInput  ? "🎙 rec"    : "—"

    print(String(
        format: "  %-28@  %-6d  %-9@  %-8@  %-36@",
        String(name.prefix(28)) as NSString, info.pid,
        outMark as NSString, inMark as NSString,
        String(bundle.prefix(36)) as NSString
    ))
}

if audioApps.isEmpty {
    print("  (no audio processes found — is coreaudiod running?)")
}
print()
print("💡 Tip: only shows apps that have registered with the CoreAudio server.")
print("   To tap a specific app:  swift run process-tap --bundle-id <bundleID>")
print()
