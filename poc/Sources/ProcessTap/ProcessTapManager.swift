/// ProcessTapManager — wraps CATapDescription + AudioHardwareCreateProcessTap.
///
/// Requires macOS 14.2.  Builds and tears down a per-process audio tap,
/// and exposes the tap's UID (a CFString) so that an aggregate device can
/// reference it.

import CoreAudio
import Foundation

// ── Errors ────────────────────────────────────────────────────────────────────

enum TapError: LocalizedError {
    case createFailed(OSStatus)
    case uidQueryFailed(OSStatus)
    case destroyFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .createFailed(let s):
            var msg = "AudioHardwareCreateProcessTap failed (OSStatus \(s))"
            if s == kAudioHardwareIllegalOperationError {
                msg += "\n  → Common causes:"
                msg += "\n    • Terminal doesn't have Microphone permission"
                msg += "\n      (System Settings → Privacy → Microphone → enable Terminal)"
                msg += "\n    • The target process has no active audio session"
                msg += "\n    • Running on macOS < 14.2"
            }
            return msg
        case .uidQueryFailed(let s):
            return "Failed to query tap UID (OSStatus \(s))"
        case .destroyFailed(let s):
            return "AudioHardwareDestroyProcessTap failed (OSStatus \(s))"
        }
    }
}

// ── ProcessTapManager ────────────────────────────────────────────────────────

@available(macOS 14.2, *)
final class ProcessTapManager {

    private(set) var activeTapIDs: [pid_t: AudioObjectID] = [:]

    // MARK: - Create

    /// Create a stereo process tap for `pid`.
    /// - Parameter mute: if true, the original app's audio is silenced while tapped.
    ///                   For PoC we keep it `.unmuted` so the user can still hear audio.
    @discardableResult
    func createTap(pid: pid_t, mute: Bool = false) throws -> AudioObjectID {
        // 1. Resolve pid to AudioObjectID of the process
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else {
            throw TapError.createFailed(kAudioHardwareIllegalOperationError)
        }
        
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else {
            throw TapError.createFailed(kAudioHardwareIllegalOperationError)
        }
        
        var processObjectID: AudioObjectID?
        for id in ids {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            var procPid: UInt32 = 0
            var pidSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &procPid) == noErr {
                if pid_t(procPid) == pid {
                    processObjectID = id
                    break
                }
            }
        }
        
        guard let targetObjID = processObjectID else {
            throw TapError.createFailed(kAudioHardwareBadObjectError) // Could not find process object
        }

        let desc = CATapDescription(stereoMixdownOfProcesses: [targetObjID])
        desc.muteBehavior = mute ? CATapMuteBehavior.muted : CATapMuteBehavior.unmuted
        desc.isPrivate    = true    // don't expose this tap to other processes

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw TapError.createFailed(status) }

        activeTapIDs[pid] = tapID
        return tapID
    }

    // MARK: - Tap UID

    /// Query the tap object's UID string — needed by the aggregate device dict.
    func tapUID(for tapID: AudioObjectID) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &uid)
        guard status == noErr, let result = uid else { throw TapError.uidQueryFailed(status) }
        return result as String
    }

    // MARK: - Destroy

    /// Tear down a tap by its AudioObjectID.
    func destroyTap(_ tapID: AudioObjectID) {
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            fputs("⚠️  destroyTap: OSStatus \(status)\n", stderr)
        }
        // Remove from tracking dict
        activeTapIDs = activeTapIDs.filter { $0.value != tapID }
    }

    /// Tear down all active taps.
    func destroyAll() {
        for (_, tapID) in activeTapIDs { destroyTap(tapID) }
    }

    deinit { destroyAll() }
}
