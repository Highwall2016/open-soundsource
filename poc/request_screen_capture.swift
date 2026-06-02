import Foundation
import CoreGraphics

let hasAccess = CGPreflightScreenCaptureAccess()
print("Has Screen Capture Access: \(hasAccess)")

if !hasAccess {
    print("Requesting access...")
    let granted = CGRequestScreenCaptureAccess()
    print("Granted: \(granted)")
}
