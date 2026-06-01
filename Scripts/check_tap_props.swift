import CoreAudio
import AVFAudio
import Foundation

var output = ""
let mirror = Mirror(reflecting: CATapDescription(stereoMixdownOfProcesses: []))
for child in mirror.children {
    output += "\(child.label ?? "") : \(type(of: child.value))\n"
}
print(output)
