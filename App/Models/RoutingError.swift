import Foundation
import CoreAudio

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
