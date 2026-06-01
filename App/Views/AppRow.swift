import SwiftUI
import AppKit

struct AppRow: View {
    let app: AppAudioInfo
    @EnvironmentObject var audioManager: AudioManager

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

                switch app.routingState {
                case .active:
                    if let deviceName = selectedDeviceName {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.green)
                            Text(deviceName)
                                .font(.caption)
                                .foregroundColor(.green)
                                .lineLimit(1)
                        }
                    }
                case .connecting:
                    HStack(spacing: 3) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Connecting…")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                case .error(let message):
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(1)
                            .help(message)
                    }
                case .idle:
                    Text("PID \(app.pid)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Right side: device picker or stop button
            switch app.routingState {
            case .active:
                HStack(spacing: 6) {
                    if let deviceName = selectedDeviceName {
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

            case .connecting:
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)

            case .error:
                Button(action: {
                    audioManager.clearError(for: app.pid)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11))
                        Text("Dismiss")
                            .font(.caption)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(6)
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)

            case .idle:
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
