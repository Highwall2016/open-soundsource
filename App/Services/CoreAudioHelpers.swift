import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.open-soundsource", category: "CoreAudioHelpers")

enum CoreAudioHelpers {

    /// Find audio process objects matching a bundle ID, with a PID-based fallback
    /// for Chromium-based browsers (Brave, Chrome, Edge) whose helpers may register
    /// audio under different bundle IDs.
    static func getProcessObjectIDs(for bundleID: String, pid: pid_t? = nil) -> [AudioObjectID] {
        let prefix = bundleID + "."

        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == noErr else { return [] }

        let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: processCount)
        AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &processIDs)

        var matched: [AudioObjectID] = []
        var pidMatched: [AudioObjectID] = []

        for processID in processIDs {
            // Check bundle ID match
            var bundleIDAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bundleIDValue: Unmanaged<CFString>? = nil
            var bundleIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

            if AudioObjectGetPropertyData(processID, &bundleIDAddr, 0, nil, &bundleIDSize, &bundleIDValue) == noErr {
                if let procBundleID = bundleIDValue?.takeRetainedValue() as String? {
                    if procBundleID == bundleID || procBundleID.hasPrefix(prefix) {
                        matched.append(processID)
                    }
                }
            }

            // Also check PID match as fallback for Chromium-based browsers
            if let targetPID = pid {
                var pidAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyPID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var procPid: UInt32 = 0
                var pidSize = UInt32(MemoryLayout<UInt32>.size)

                if AudioObjectGetPropertyData(processID, &pidAddr, 0, nil, &pidSize, &procPid) == noErr {
                    if pid_t(procPid) == targetPID {
                        pidMatched.append(processID)
                    }
                }
            }
        }

        if !matched.isEmpty {
            // Log which matched objects are actually running output
            for objID in matched {
                var pidAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyPID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var procPid: UInt32 = 0
                var pidSize = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSize, &procPid)

                var isOutputAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyIsRunningOutput,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var isOutput: UInt32 = 0
                var boolSize = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(objID, &isOutputAddr, 0, nil, &boolSize, &isOutput)

                logger.info("  Process object \(objID): pid=\(procPid), isRunningOutput=\(isOutput)")
            }
            logger.info("Found \(matched.count) process objects by bundleID '\(bundleID)'")
            return matched
        }

        // Fallback: use PID-matched objects if bundle ID match found nothing
        if !pidMatched.isEmpty {
            logger.info("BundleID match empty; using \(pidMatched.count) PID-matched process objects for pid \(pid ?? 0)")
            return pidMatched
        }

        logger.warning("No process objects found for bundleID '\(bundleID)' or pid \(pid ?? 0)")
        return []
    }

    static func getDeviceUID(for deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidValue: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uidValue)
        guard status == noErr, let uid = uidValue?.takeRetainedValue() as String? else { return nil }
        return uid
    }

    static func getDeviceName(for deviceID: AudioDeviceID) -> String? {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameValue: Unmanaged<CFString>? = nil
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        if AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameValue) == noErr {
            return nameValue?.takeRetainedValue() as String?
        }
        return nil
    }
}
