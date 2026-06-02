import Foundation
import CoreAudio
import AppKit
import AVFAudio
import os.log

private let logger = Logger(subsystem: "com.open-soundsource", category: "AudioManager")

/// Holds all the CoreAudio resources for one active routing session.
private struct RoutingSession {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    let engine: AVAudioEngine
    let playerNode: AVAudioPlayerNode
    let captureUnit: AudioUnit
    let captureContext: Unmanaged<CaptureContext>
}

/// Mutable state shared between the render callback and the session owner.
private class CaptureContext {
    let captureUnit: AudioUnit
    let playerNode: AVAudioPlayerNode
    let captureFormat: AVAudioFormat
    let playbackFormat: AVAudioFormat
    let converter: AVAudioConverter?
    var bufferCount: UInt64 = 0
    var hasEverHadAudio: Bool = false
    var silenceWarningLogged: Bool = false

    init(captureUnit: AudioUnit, playerNode: AVAudioPlayerNode,
         captureFormat: AVAudioFormat, playbackFormat: AVAudioFormat,
         converter: AVAudioConverter?) {
        self.captureUnit = captureUnit
        self.playerNode = playerNode
        self.captureFormat = captureFormat
        self.playbackFormat = playbackFormat
        self.converter = converter
    }
}

@MainActor
class AudioManager: ObservableObject {
    @Published var apps: [AppAudioInfo] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var deviceVolumes: [AudioDeviceID: Float] = [:]

    private var sessions: [pid_t: RoutingSession] = [:]

    init() {
        cleanupOrphanedDevices()
        cleanupOrphanedTaps()
        refreshOutputDevices()
        refreshApps()
    }

    // MARK: - Cleanup

    /// Destroy any aggregate devices left behind by a previous crash or force-quit.
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

    /// Destroy any process taps left behind by a previous crash or force-quit.
    /// Without this, tapped apps (e.g. Brave) remain muted permanently.
    /// Preserves taps belonging to currently active routing sessions.
    private func cleanupOrphanedTaps() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var tapIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &tapIDs) == noErr else { return }

        let activeSessionTapIDs = Set(sessions.values.map(\.tapID))
        for tapID in tapIDs {
            if activeSessionTapIDs.contains(tapID) {
                logger.info("Keeping active session tap \(tapID)")
                continue
            }
            logger.info("Destroying orphaned process tap \(tapID)")
            AudioHardwareDestroyProcessTap(tapID)
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
            var chanAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var chanSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &chanAddr, 0, nil, &chanSize) != noErr || chanSize == 0 {
                continue
            }
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

            guard let name = CoreAudioHelpers.getDeviceName(for: id),
                  let uid = CoreAudioHelpers.getDeviceUID(for: id) else { continue }

            if name.hasPrefix("OSS") || uid == "com.open-soundsource.device" {
                continue
            }
            newDevices.append(AudioDevice(id: id, name: name, uid: uid))
        }

        self.outputDevices = newDevices
        refreshDeviceVolumes()
    }

    // MARK: - Device Volume Control

    func refreshDeviceVolumes() {
        var volumes: [AudioDeviceID: Float] = [:]
        for device in outputDevices {
            if let vol = CoreAudioHelpers.getDeviceVolume(for: device.id) {
                volumes[device.id] = vol
            }
        }
        self.deviceVolumes = volumes
    }

    func setDeviceVolume(for deviceID: AudioDeviceID, volume: Float) {
        CoreAudioHelpers.setDeviceVolume(for: deviceID, volume: volume)
        deviceVolumes[deviceID] = max(0, min(1, volume))
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
                    if bundleId == Bundle.main.bundleIdentifier || bundleId.lowercased().contains("helper") { continue }
                    if newApps.contains(where: { $0.bundleId == bundleId }) { continue }

                    var routingState: RoutingState = .idle
                    var selectedDevice: AudioDeviceID? = nil
                    var volume: Float = 1.0
                    if let existing = self.apps.first(where: { $0.pid == pid }) {
                        routingState = existing.routingState
                        selectedDevice = existing.selectedOutputDeviceID
                        volume = existing.volume
                    } else if sessions.keys.contains(pid) {
                        routingState = .active
                    }

                    let info = AppAudioInfo(
                        id: pid,
                        name: name,
                        bundleId: bundleId,
                        pid: pid,
                        routingState: routingState,
                        selectedOutputDeviceID: selectedDevice,
                        volume: volume
                    )
                    newApps.append(info)
                }
            }
        }

        self.apps = newApps.sorted(by: { $0.name < $1.name })
    }

    // MARK: - Routing Control

    func startRouting(for pid: pid_t, to outputDeviceID: AudioDeviceID) {
        stopRouting(for: pid)

        // Clean up any orphaned taps from previous sessions before creating new ones,
        // because an orphaned muted tap can silently steal audio from the target process.
        cleanupOrphanedTaps()

        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        guard let outputDevice = outputDevices.first(where: { $0.id == outputDeviceID }) else {
            logger.error("Output device not found: \(outputDeviceID)")
            setRoutingError(for: pid, message: "Output device not found")
            return
        }

        // Immediately show connecting state in UI
        if let index = apps.firstIndex(where: { $0.pid == pid }) {
            apps[index].routingState = .connecting
            apps[index].selectedOutputDeviceID = outputDeviceID
        }
        logger.info("Starting routing for PID \(pid) (\(bundleID)) -> \(outputDevice.name)")

        Task.detached { [weak self] in
            guard let self = self else { return }

            do {
                let session = try await self.createRoutingSession(
                    pid: pid,
                    bundleID: bundleID,
                    outputDeviceUID: outputDevice.uid,
                    outputDeviceID: outputDevice.id
                )
                await MainActor.run {
                    self.sessions[pid] = session
                    if let index = self.apps.firstIndex(where: { $0.pid == pid }) {
                        self.apps[index].routingState = .active
                        self.apps[index].selectedOutputDeviceID = outputDeviceID
                    }
                    logger.info("Routing active for PID \(pid) -> device \(outputDevice.name)")
                }
            } catch {
                let errorMsg = error.localizedDescription
                logger.error("Failed to start routing for PID \(pid): \(error)")
                await MainActor.run {
                    self.setRoutingError(for: pid, message: errorMsg)
                }
            }
        }
    }

    private func setRoutingError(for pid: pid_t, message: String) {
        if let index = apps.firstIndex(where: { $0.pid == pid }) {
            apps[index].routingState = .error(message)
            apps[index].selectedOutputDeviceID = nil
        }
    }

    func clearError(for pid: pid_t) {
        if let index = apps.firstIndex(where: { $0.pid == pid }) {
            apps[index].routingState = .idle
        }
    }

    func stopRouting(for pid: pid_t) {
        guard let session = sessions[pid] else { return }

        AudioOutputUnitStop(session.captureUnit)
        AudioComponentInstanceDispose(session.captureUnit)
        session.captureContext.release()
        session.playerNode.stop()
        session.engine.stop()
        AudioHardwareDestroyAggregateDevice(session.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(session.tapID)

        sessions.removeValue(forKey: pid)

        if let index = apps.firstIndex(where: { $0.pid == pid }) {
            apps[index].routingState = .idle
            apps[index].selectedOutputDeviceID = nil
            apps[index].volume = 1.0
        }

        logger.info("Routing stopped for PID \(pid)")
    }

    // MARK: - Volume Control

    func setVolume(for pid: pid_t, volume: Float) {
        let clamped = max(0, min(1, volume))
        if let session = sessions[pid] {
            session.playerNode.volume = clamped
        }
        if let index = apps.firstIndex(where: { $0.pid == pid }) {
            apps[index].volume = clamped
        }
    }

    /// Tear down every active routing session. Called on app termination to
    /// ensure process taps are destroyed and muted apps regain their audio.
    func stopAllRouting() {
        let activePIDs = Array(sessions.keys)
        for pid in activePIDs {
            stopRouting(for: pid)
        }
        logger.info("All routing sessions stopped (\(activePIDs.count) total)")
    }

    // MARK: - Core Routing Implementation

    private nonisolated func createRoutingSession(
        pid: pid_t,
        bundleID: String,
        outputDeviceUID: String,
        outputDeviceID: AudioDeviceID
    ) async throws -> RoutingSession {
        let processObjectIDs = CoreAudioHelpers.getProcessObjectIDs(for: bundleID, pid: pid)
        guard !processObjectIDs.isEmpty else {
            throw RoutingError.processNotFound(pid)
        }
        logger.info("Found \(processObjectIDs.count) process objects for \(bundleID): \(processObjectIDs)")

        // -- 1. Create process tap (mutes original output) --
        let tapUUID = UUID()
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        desc.uuid = tapUUID
        desc.isPrivate = false
        desc.muteBehavior = .muted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
        guard tapStatus == noErr else {
            throw RoutingError.tapCreationFailed(tapStatus)
        }
        logger.info("Created process tap \(tapID) for PID \(pid)")

        // Query the actual tap UID assigned by CoreAudio — it may differ
        // from the UUID we set on CATapDescription.
        var tapUIDAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapUIDValue: Unmanaged<CFString>? = nil
        var tapUIDSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let actualTapUID: String
        if AudioObjectGetPropertyData(tapID, &tapUIDAddr, 0, nil, &tapUIDSize, &tapUIDValue) == noErr,
           let uid = tapUIDValue?.takeRetainedValue() as String? {
            actualTapUID = uid
        } else {
            actualTapUID = tapUUID.uuidString
        }
        logger.info("Tap UID: set=\(tapUUID.uuidString) actual=\(actualTapUID)")

        // -- 2. Create tap-only aggregate device --
        // Do NOT add a hardware sub-device as clock source. When the clock
        // device (e.g. BuiltInSpeakerDevice) runs at a different sample rate
        // than the tapped process's output (e.g. 48 kHz vs 44.1 kHz for
        // Bluetooth), and drift compensation is off, the tap delivers silence.
        // A tap-only aggregate uses the tap's own clock, which is always in
        // sync with the audio the process produces.
        let tapConfig: [String: Any] = [
            kAudioSubTapUIDKey: actualTapUID,
            kAudioSubTapDriftCompensationKey: false
        ]
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OSS_Route_\(pid)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [tapConfig]
        ]

        var aggregateDeviceID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggregateDeviceID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(aggStatus)
        }
        logger.info("Created tap-only aggregate device \(aggregateDeviceID)")

        try await Task.sleep(nanoseconds: 500_000_000)

        // -- 3. Create standalone AUHAL for capture from the aggregate device --
        // We use a raw AudioUnit instead of AVAudioEngine.inputNode because
        // AVAudioEngine ties its inputNode/outputNode into a single graph that
        // breaks (-10875) when the input device is a tap-only aggregate.
        var captureComponentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &captureComponentDesc) else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(-10860)
        }
        var optCaptureUnit: AudioUnit?
        var cuStatus = AudioComponentInstanceNew(component, &optCaptureUnit)
        guard cuStatus == noErr, let captureUnit = optCaptureUnit else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(cuStatus)
        }

        // Enable input, disable output on capture AUHAL
        var one: UInt32 = 1
        var zero: UInt32 = 0
        AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))

        // Point capture at the aggregate device
        var devID = aggregateDeviceID
        cuStatus = AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_CurrentDevice,
                                        kAudioUnitScope_Global, 0, &devID,
                                        UInt32(MemoryLayout<AudioDeviceID>.size))
        guard cuStatus == noErr else {
            AudioComponentInstanceDispose(captureUnit)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(cuStatus)
        }

        // Query the aggregate device's actual sample rate — the AUHAL default
        // output format may report 44100 Hz even when the device runs at 48000 Hz,
        // causing AudioUnitRender to fail on every callback.
        var aggNominalSR: Float64 = 0
        var aggSRSize = UInt32(MemoryLayout<Float64>.size)
        var aggSRAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(aggregateDeviceID, &aggSRAddr, 0, nil, &aggSRSize, &aggNominalSR)

        var captureASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        cuStatus = AudioUnitGetProperty(captureUnit, kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Output, 1, &captureASBD, &asbdSize)
        guard cuStatus == noErr else {
            logger.error("Failed to read capture AUHAL format: \(cuStatus)")
            AudioComponentInstanceDispose(captureUnit)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(cuStatus)
        }
        let captureChannels = captureASBD.mChannelsPerFrame > 0 ? captureASBD.mChannelsPerFrame : 2
        // Use the device's actual sample rate, not the AUHAL's default
        let captureSampleRate = aggNominalSR > 0 ? aggNominalSR : (captureASBD.mSampleRate > 0 ? captureASBD.mSampleRate : 48000)
        logger.info("Capture AUHAL format: \(captureChannels) ch, \(Int(captureSampleRate)) Hz (device SR: \(Int(aggNominalSR)))")

        // Set a known float32 format on the output scope (what we read from the callback)
        let captureFormat = AVAudioFormat(standardFormatWithSampleRate: captureSampleRate,
                                          channels: AVAudioChannelCount(captureChannels))!
        var outASBD = captureFormat.streamDescription.pointee
        cuStatus = AudioUnitSetProperty(captureUnit, kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Output, 1, &outASBD,
                                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard cuStatus == noErr else {
            logger.error("Failed to set capture AUHAL format: \(cuStatus)")
            AudioComponentInstanceDispose(captureUnit)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(cuStatus)
        }

        // -- 4. Set up playback engine targeting the output device --
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        // Disable input on output AUHAL to prevent Bluetooth HFP
        if let outputAU = engine.outputNode.audioUnit {
            AudioUnitSetProperty(outputAU, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input, 1, &zero,
                                 UInt32(MemoryLayout<UInt32>.size))
        }

        do {
            try engine.outputNode.auAudioUnit.setDeviceID(outputDeviceID)
        } catch {
            logger.error("Failed to set output device: \(error)")
            AudioComponentInstanceDispose(captureUnit)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(-10861)
        }

        let outputHWFormat = engine.outputNode.outputFormat(forBus: 0)
        let outputSampleRate = outputHWFormat.sampleRate > 0 ? outputHWFormat.sampleRate : 48000
        let outputChannels = outputHWFormat.channelCount > 0 ? outputHWFormat.channelCount : 2
        logger.info("Output HW format: \(outputChannels) ch, \(Int(outputSampleRate)) Hz")

        let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate,
                                           channels: AVAudioChannelCount(outputChannels))!
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        engine.mainMixerNode.outputVolume = 1.0

        // -- 5. Set up converter and render callback --
        var converter: AVAudioConverter? = nil
        let needsConversion = abs(captureSampleRate - outputSampleRate) > 1.0
            || captureChannels != AVAudioChannelCount(outputChannels)
        if needsConversion {
            converter = AVAudioConverter(from: captureFormat, to: playbackFormat)
            logger.info("Converter: \(captureChannels)ch/\(Int(captureSampleRate))Hz -> \(outputChannels)ch/\(Int(outputSampleRate))Hz")
        }

        let context = CaptureContext(
            captureUnit: captureUnit,
            playerNode: playerNode,
            captureFormat: captureFormat,
            playbackFormat: playbackFormat,
            converter: converter
        )
        let contextRetained = Unmanaged.passRetained(context)

        var callbackStruct = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _) -> OSStatus in
                let ctx = Unmanaged<CaptureContext>.fromOpaque(inRefCon).takeUnretainedValue()

                if ctx.bufferCount == 0 {
                    logger.info("First render callback fired!")
                }

                guard let buffer = AVAudioPCMBuffer(pcmFormat: ctx.captureFormat,
                                                     frameCapacity: inNumberFrames) else { return noErr }
                buffer.frameLength = inNumberFrames

                // Render captured audio from the aggregate device via our AUHAL
                let renderStatus = withUnsafeMutablePointer(to: &buffer.mutableAudioBufferList.pointee) { ablPtr in
                    AudioUnitRender(ctx.captureUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ablPtr)
                }
                
                if renderStatus != noErr {
                    if ctx.bufferCount % 100 == 0 {
                        logger.error("AudioUnitRender failed: \(renderStatus)")
                    }
                    ctx.bufferCount += 1
                    return noErr
                }

                // Periodic logging to confirm audio flow
                ctx.bufferCount += 1
                if ctx.bufferCount % 500 == 1 {
                    var peak: Float = 0
                    if let channelData = buffer.floatChannelData {
                        for channel in 0..<Int(buffer.format.channelCount) {
                            for frame in 0..<Int(buffer.frameLength) {
                                let sample = abs(channelData[channel][frame])
                                if sample > peak { peak = sample }
                            }
                        }
                    }
                    if peak > 0.0001 {
                        ctx.hasEverHadAudio = true
                    }
                    logger.info("Audio flow: buf#\(ctx.bufferCount) frames=\(buffer.frameLength) peak=\(peak)")

                    // Warn once if we've captured ~5 seconds of pure silence
                    // (~500 buffers * 512 frames / 48000 Hz ≈ 5.3s)
                    if ctx.bufferCount >= 500 && !ctx.hasEverHadAudio && !ctx.silenceWarningLogged {
                        ctx.silenceWarningLogged = true
                        logger.warning("Persistent silence detected — the tapped process may not be producing audio. Check that audio is playing in the app.")
                    }
                }

                // Forward to playerNode, converting format if needed
                if let converter = ctx.converter {
                    let ratio = ctx.playbackFormat.sampleRate / ctx.captureFormat.sampleRate
                    let chRatio = Double(ctx.playbackFormat.channelCount) / Double(ctx.captureFormat.channelCount)
                    let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio * chRatio) + 1
                    guard let outBuf = AVAudioPCMBuffer(pcmFormat: ctx.playbackFormat,
                                                         frameCapacity: outCap) else { return noErr }
                    var err: NSError?
                    var consumed = false
                    converter.convert(to: outBuf, error: &err) { _, outStatus in
                        if !consumed { consumed = true; outStatus.pointee = .haveData; return buffer }
                        outStatus.pointee = .noDataNow; return nil
                    }
                    if err == nil && outBuf.frameLength > 0 {
                        ctx.playerNode.scheduleBuffer(outBuf)
                    }
                } else {
                    ctx.playerNode.scheduleBuffer(buffer)
                }
                return noErr
            },
            inputProcRefCon: contextRetained.toOpaque()
        )

        cuStatus = AudioUnitSetProperty(captureUnit, kAudioOutputUnitProperty_SetInputCallback,
                                        kAudioUnitScope_Global, 0, &callbackStruct,
                                        UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard cuStatus == noErr else {
            logger.error("Failed to set input callback: \(cuStatus)")
            contextRetained.release()
            AudioComponentInstanceDispose(captureUnit)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(cuStatus)
        }

        cuStatus = AudioUnitInitialize(captureUnit)
        guard cuStatus == noErr else {
            logger.error("Failed to initialize capture AUHAL: \(cuStatus)")
            contextRetained.release()
            AudioComponentInstanceDispose(captureUnit)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RoutingError.aggregateCreationFailed(cuStatus)
        }

        // -- 6. Start everything --
        func cleanupOnFailure() {
            AudioOutputUnitStop(captureUnit)
            AudioUnitUninitialize(captureUnit)
            AudioComponentInstanceDispose(captureUnit)
            contextRetained.release()
            playerNode.stop()
            engine.stop()
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            logger.error("Playback engine start failed: \(error)")
            cleanupOnFailure()
            throw error
        }
        playerNode.play()

        let startStatus = AudioOutputUnitStart(captureUnit)
        guard startStatus == noErr else {
            logger.error("Capture AUHAL start failed: \(startStatus)")
            cleanupOnFailure()
            throw RoutingError.aggregateCreationFailed(startStatus)
        }

        logger.info("Routing active for PID \(pid) — playback engine + capture AUHAL running")

        // Quick verification: check aggregate device stream config
        var verifyStreamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var verifyStreamSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(aggregateDeviceID, &verifyStreamAddr, 0, nil, &verifyStreamSize) == noErr {
            let bufPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufPtr.deallocate() }
            if AudioObjectGetPropertyData(aggregateDeviceID, &verifyStreamAddr, 0, nil, &verifyStreamSize, bufPtr) == noErr {
                let bufList = UnsafeMutableAudioBufferListPointer(bufPtr)
                var totalCh: UInt32 = 0
                for buf in bufList { totalCh += buf.mNumberChannels }
                logger.info("Aggregate device input streams: \(bufList.count) buffers, \(totalCh) total channels")
            }
        }

        return RoutingSession(
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            engine: engine,
            playerNode: playerNode,
            captureUnit: captureUnit,
            captureContext: contextRetained
        )
    }
}
