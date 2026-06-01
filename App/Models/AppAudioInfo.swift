import Foundation
import CoreAudio

enum RoutingState: Equatable {
    case idle
    case connecting
    case active
    case error(String)

    var isRouting: Bool {
        if case .active = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

struct AppAudioInfo: Identifiable {
    let id: pid_t
    let name: String
    let bundleId: String
    let pid: pid_t
    var routingState: RoutingState = .idle
    var selectedOutputDeviceID: AudioDeviceID? = nil

    var isRouting: Bool { routingState.isRouting }
}
