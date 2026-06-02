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
        var runningOutputMatched: [AudioObjectID] = []
        var pidMatched: [AudioObjectID] = []
        var runningOutputPIDMatched: [AudioObjectID] = []

        for processID in processIDs {
            // Check bundle ID match
            var bundleIDAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var bundleIDValue: Unmanaged<CFString>? = nil
            var bundleIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

            var isOutputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isOutput: UInt32 = 0
            var boolSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(processID, &isOutputAddr, 0, nil, &boolSize, &isOutput)

            if AudioObjectGetPropertyData(processID, &bundleIDAddr, 0, nil, &bundleIDSize, &bundleIDValue) == noErr {
                if let procBundleID = bundleIDValue?.takeRetainedValue() as String? {
                    if procBundleID == bundleID || procBundleID.hasPrefix(prefix) {
                        matched.append(processID)
                        if isOutput == 1 {
                            runningOutputMatched.append(processID)
                        }
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
                        if isOutput == 1 {
                            runningOutputPIDMatched.append(processID)
                        }
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
            if !runningOutputMatched.isEmpty {
                logger.info("Active output process objects for '\(bundleID)': \(runningOutputMatched)")
                // Prefer only the processes actively outputting audio — tapping
                // silent helper processes can cause the tap to capture all zeros.
                return runningOutputMatched
            }
            logger.warning("No process objects with isRunningOutput=1 for '\(bundleID)' — using all \(matched.count) matches (audio may not be playing)")
            return matched
        }

        // Fallback: use PID-matched objects if bundle ID match found nothing
        if !pidMatched.isEmpty {
            logger.info("BundleID match empty; using \(pidMatched.count) PID-matched process objects for pid \(pid ?? 0)")
            if !runningOutputPIDMatched.isEmpty {
                logger.info("Active output PID-matched process objects for pid \(pid ?? 0): \(runningOutputPIDMatched)")
                return runningOutputPIDMatched
            }
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

    static func getPreferredClockOutputDeviceUID(targetUID: String, defaultUID: String?) -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else {
            return targetUID
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &deviceIDs) == noErr else {
            return targetUID
        }

        var speakerUID: String?
        var targetExists = false
        var defaultExists = false
        for id in deviceIDs {
            var chanAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var chanSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &chanAddr, 0, nil, &chanSize) == noErr, chanSize > 0 else {
                continue
            }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            guard AudioObjectGetPropertyData(id, &chanAddr, 0, nil, &chanSize, bufferListPtr) == noErr else {
                continue
            }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let totalChannels = bufferList.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
            guard totalChannels > 0,
                  let uid = getDeviceUID(for: id),
                  uid != "com.open-soundsource.device",
                  let name = getDeviceName(for: id),
                  !name.hasPrefix("OSS") else {
                continue
            }

            if uid == targetUID {
                targetExists = true
            }
            if uid == defaultUID {
                defaultExists = true
            }
            if uid == "BuiltInSpeakerDevice" || name.localizedCaseInsensitiveContains("speaker") {
                speakerUID = uid
            }
        }

        if let speakerUID {
            return speakerUID
        }
        if let defaultUID, defaultExists {
            return defaultUID
        }
        if targetExists {
            return targetUID
        }
        return "BuiltInSpeakerDevice"
    }
}
