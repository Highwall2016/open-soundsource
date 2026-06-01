// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "oss-poc",
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .executable(name: "list-devices", targets: ["list-devices"]),
        .executable(name: "list-apps",    targets: ["list-apps"]),
        .executable(name: "process-tap",  targets: ["process-tap"]),
    ],
    targets: [
        // ── Tool 1: enumerate audio output devices ──────────────────────────
        .executableTarget(
            name: "list-devices",
            path: "Sources/ListDevices",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),

        // ── Tool 2: list running apps that are using audio ──────────────────
        .executableTarget(
            name: "list-apps",
            path: "Sources/ListApps",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
            ]
        ),

        // ── Tool 3: tap a process and show a live terminal VU meter ─────────
        //   Requires macOS 14.2+ for CATapDescription / AudioHardwareCreateProcessTap
        .executableTarget(
            name: "process-tap",
            path: "Sources/ProcessTap",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
