import CoreAudio
import AVFAudio
import Foundation

let desc = CATapDescription(stereoMixdownOfProcesses: [])
desc.muteBehavior = .muted
print("Set muteBehavior successfully!")
