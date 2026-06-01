import Foundation
import AVFAudio
import AppKit

let engine = AVAudioEngine()
let inputNode = engine.inputNode
let outputNode = engine.outputNode
print("Engine created")
