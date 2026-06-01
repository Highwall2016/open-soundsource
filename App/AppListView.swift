import SwiftUI
import AppKit

struct AppListView: View {
    @EnvironmentObject var audioManager: AudioManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.accentColor)
                Text("OpenSoundSource")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: {
                    audioManager.refreshOutputDevices()
                    audioManager.refreshApps()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if audioManager.apps.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "speaker.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No audio apps detected")
                        .foregroundColor(.secondary)
                    Text("Play audio in an app to see it here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(audioManager.apps) { app in
                            AppRow(app: app)
                                .environmentObject(audioManager)
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("Output devices: \(audioManager.outputDevices.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

struct AppRow: View {
    let app: AppAudioInfo
    @EnvironmentObject var audioManager: AudioManager

    /// Name of the currently selected device (for display in the button)
    private var selectedDeviceName: String? {
        guard let id = app.selectedOutputDeviceID else { return nil }
        return audioManager.outputDevices.first(where: { $0.id == id })?.name
    }

    var body: some View {
        HStack(spacing: 10) {
            // App icon
            Group {
                if let runningApp = NSRunningApplication(processIdentifier: app.pid),
                   let icon = runningApp.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .cornerRadius(6)

            // App name + routing status
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if app.isRouting, let deviceName = selectedDeviceName {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.green)
                        Text(deviceName)
                            .font(.caption)
                            .foregroundColor(.green)
                            .lineLimit(1)
                    }
                } else {
                    Text("PID \(app.pid)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Right side: device picker or stop button
            if app.isRouting {
                // Show device name button + stop X
                HStack(spacing: 6) {
                    if let deviceName = selectedDeviceName {
                        // Tappable label to change device while routing
                        Menu {
                            ForEach(audioManager.outputDevices) { device in
                                Button(device.name) {
                                    audioManager.startRouting(for: app.pid, to: device.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 11))
                                Text(deviceName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .frame(maxWidth: 130)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(6)
                            .foregroundColor(.green)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    Button(action: {
                        audioManager.stopRouting(for: app.pid)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Stop routing")
                }
            } else {
                // Route picker — clicking opens device list
                Menu {
                    if audioManager.outputDevices.isEmpty {
                        Text("No output devices found")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(audioManager.outputDevices) { device in
                            Button(device.name) {
                                audioManager.startRouting(for: app.pid, to: device.id)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 11))
                        Text("Route")
                            .font(.caption)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(6)
                    .foregroundColor(.accentColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
    }
}
