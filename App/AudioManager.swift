import Foundation
import CoreAudio
import AppKit
import AVFAudio

struct AppAudioInfo: Identifiable {
    let id: pid_t  // Use pid as stable identity
    let name: String
    let bundleId: String
    let pid: pid_t
    var isRouting: Bool = false
    var selectedOutputDeviceID: AudioDeviceID? = nil
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// Holds all the CoreAudio resources for one active routing session.
private struct RoutingSession {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    let engine: AVAudioEngine
}

@MainActor
class AudioManager: ObservableObject {
    @Published var apps: [AppAudioInfo] = []
    @Published var outputDevices: [AudioDevice] = []

    /// Active routing sessions keyed by app PID.
    private var sessions: [pid_t: RoutingSession] = [:]

    init() {
        cleanupOrphanedDevices()
        refreshOutputDevices()
        refreshApps()
    }
    
    private func cleanupOrphanedDevices() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr {
            let count = Int(size) / MemoryLayout<AudioDeviceID>.size
            var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
            if AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &deviceIDs) == noErr {
                for id in deviceIDs {
                    var nameAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioObjectPropertyName,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    var nameValue: Unmanaged<CFString>? = nil
                    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                    
                    if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameValue) == noErr {
                        if let name = nameValue?.takeRetainedValue() as String?, name.hasPrefix("OSS_Route") {
                            AudioHardwareDestroyAggregateDevice(id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Device Enumeration

    func refreshOutputDevices() {
        var newDevices: [AudioDevice] = []

        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &deviceIDs) == noErr else { return }

        for id in deviceIDs {
            // Check if it has output channels (not just streams)
            var chanAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var chanSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &chanAddr, 0, nil, &chanSize) != noErr || chanSize == 0 {
                continue
            }
            // Check the actual channel count
            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            if AudioObjectGetPropertyData(id, &chanAddr, 0, nil, &chanSize, bufferListPtr) != noErr {
                continue
            }
            var totalChannels: UInt32 = 0
            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            for buf in bufferList {
                totalChannels += buf.mNumberChannels
            }
            if totalChannels == 0 {
                continue
            }

            // Get name and UID
            guard let name = getDeviceName(for: id), let uid = getDeviceUID(for: id) else { continue }

            // Skip our own aggregate devices and the OpenSoundSource virtual driver
            if name.hasPrefix("OSS") || uid == "com.open-soundsource.device" {
                continue
            }
            newDevices.append(AudioDevice(id: id, name: name, uid: uid))
        }

        self.outputDevices = newDevices
    }

    // MARK: - App Enumeration

    func refreshApps() {
        var newApps: [AppAudioInfo] = []

        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return }

        let runningApps = NSWorkspace.shared.runningApplications
        var processAppMap = [pid_t: NSRunningApplication]()
        for app in runningApps {
            processAppMap[app.processIdentifier] = app
        }

        for id in ids {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var procPid: UInt32 = 0
            var pidSize = UInt32(MemoryLayout<UInt32>.size)

            if AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &procPid) == noErr {
                let pid = pid_t(procPid)
                if let app = processAppMap[pid], let bundleId = app.bundleIdentifier, let name = app.localizedName {
                    // Ignore ourselves and helper processes to avoid UI clutter
                    if bundleId == Bundle.main.bundleIdentifier || bundleId.lowercased().contains("helper") { continue }
                    
                    // Check if we already have an app with this bundle ID in newApps to avoid duplicates
                    if newApps.contains(where: { $0.bundleId == bundleId }) { continue }

                    // Preserve existing routing state
                    let isRouting = sessions.keys.contains(pid)
                    var selectedDevice: AudioDeviceID? = nil
                    if let existing = self.apps.first(where: { $0.pid == pid }) {
                        selectedDevice = existing.selectedOutputDeviceID
                    }

                    let info = AppAudioInfo(
                        id: pid,
                        name: name,
                        bundleId: bundleId,
                        pid: pid,
                        isRouting: isRouting,
                        selectedOutputDeviceID: selectedDevice
                    )
                    newApps.append(info)
                }
            }
        }

        self.apps = newApps.sorted(by: { $0.name < $1.name })
    }

    // MARK: - Routing Control

    /// Start routing audio from an app to a specific output device.
    func startRouting(for pid: pid_t, to outputDeviceID: AudioDeviceID) {
        // Stop any existing routing for this app first
        stopRouting(for: pid)

        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        guard let outputDevice = outputDevices.first(where: { $0.id == outputDeviceID }) else {
            print("❌ Output device not found: \(outputDeviceID)")
            return
        }

        Task.detached { [weak self] in
            guard let self = self else { return }

            do {
                let session = try await self.createRoutingSession(
                    pid: pid,
                    bundleID: bundleID,
                    outputDeviceUID: outputDevice.uid
                )
                await MainActor.run {
                    self.sessions[pid] = session
                    if let index = self.apps.firstIndex(where: { $0.pid == pid }) {
                        self.apps[index].isRouting = true
                        self.apps[index].selectedOutputDeviceID = outputDeviceID
                    }
                    print("✅ Routing started for PID \(pid) → device \(outputDevice.name)")
                }
            } catch {
                print("❌ Failed to start routing for PID \(pid): \(error)")
            }
        }
    }

    /// Stop routing audio for an app.
    func stopRouting(for pid: pid_t) {
        guard let session = sessions[pid] else { return }

        // Stop the engine
        session.engine.stop()

        // Destroy aggregate device
        AudioHardwareDestroyAggregateDevice(session.aggregateDeviceID)

        // Destroy the process tap
        AudioHardwareDestroyProcessTap(session.tapID)

        sessions.removeValue(forKey: pid)

        if let index = apps.firstIndex(where: { $0.pid == pid }) {
            apps[index].isRouting = false
            apps[index].selectedOutputDeviceID = nil
        }

        print("🔇 Routing stopped for PID \(pid)")
    }

    // MARK: - Core Routing Implementation

    private nonisolated func createRoutingSession(
        pid: pid_t,
        bundleID: String,
        outputDeviceUID: String
    ) async throws -> RoutingSession {
        // 1. Find ALL process object IDs for the bundle (captures helper processes too)
        let processObjectIDs = getProcessObjectIDs(for: bundleID)
        guard !processObjectIDs.isEmpty else {
            throw RoutingError.processNotFound(pid)
        }
        print("🔍 Found \(processObjectIDs.count) process objects for \(bundleID)")

        // 2. Create the process tap
        let tapUUID = UUID()
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        desc.uuid = tapUUID
        desc.isPrivate = false  // Must be false to be visible as a tap source
        desc.muteBehavior = .muted  // Mute the app from the default system output so it only plays via our route

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
        guard tapStatus == noErr else {
            throw RoutingError.tapCreationFailed(tapStatus)
        }
        print("🎤 Created process tap \(tapID) for PID \(pid)")

        // 3. Create aggregate device with:
        //    - Sub-device: the target output speaker
        //    - Tap list: the process tap (provides input from the app's audio)
        let tapConfig: [String: Any] = [
            kAudioSubTapUIDKey: tapUUID.uuidString
        ]
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OSS_Route_\(pid)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceMasterSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceTapListKey: [tapConfig],
            kAudioAggregateDeviceIsPrivateKey: 0
        ]

        var aggregateDeviceID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggregateDeviceID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(aggStatus)
        }
        print("📦 Created aggregate device \(aggregateDeviceID)")

        // Brief pause for Core Audio to register the aggregate device
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms

        // 4. Set up AVAudioEngine with the aggregate device
        let engine = AVAudioEngine()
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(aggregateDeviceID)
            try engine.inputNode.auAudioUnit.setDeviceID(aggregateDeviceID)
        } catch {
            print("⚠️ Failed to set device ID: \(error)")
            AudioHardwareDestroyProcessTap(tapID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            throw RoutingError.aggregateCreationFailed(-10851)
        }

        // Connect input → mixer with nil format to let the engine auto-negotiate
        // (The tap input may report 0 channels initially, but nil format handles this)
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: nil)

        // Start the engine
        engine.prepare()
        try engine.start()
        print("▶️ AVAudioEngine started for PID \(pid)")

        return RoutingSession(
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            engine: engine
        )
    }

    // MARK: - CoreAudio Helpers

    private nonisolated func getProcessObjectIDs(for bundleID: String) -> [AudioObjectID] {
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
        for processID in processIDs {
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
        }
        return matched
    }

    private nonisolated func getDeviceUID(for deviceID: AudioDeviceID) -> String? {
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

    private nonisolated func getDeviceName(for deviceID: AudioDeviceID) -> String? {
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

// MARK: - Errors

enum RoutingError: LocalizedError {
    case processNotFound(pid_t)
    case tapCreationFailed(OSStatus)
    case deviceUIDNotFound(AudioDeviceID)
    case aggregateCreationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .processNotFound(let pid): return "Process not found for PID \(pid)"
        case .tapCreationFailed(let s): return "AudioHardwareCreateProcessTap failed: \(s)"
        case .deviceUIDNotFound(let id): return "Could not get UID for device \(id)"
        case .aggregateCreationFailed(let s): return "AudioHardwareCreateAggregateDevice failed: \(s)"
        }
    }
}
