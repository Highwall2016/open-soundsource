import Foundation
import AVFAudio

let engine = AVAudioEngine()
if let unit = engine.inputNode.audioUnit {
    print("Not nil: \(unit)")
} else {
    print("Nil")
}
