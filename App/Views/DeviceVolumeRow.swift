import SwiftUI

struct DeviceVolumeRow: View {
    let device: AudioDevice
    @EnvironmentObject var audioManager: AudioManager

    private var volume: Float {
        audioManager.deviceVolumes[device.id] ?? 1.0
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(device.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)

            Slider(
                value: Binding(
                    get: { volume },
                    set: { audioManager.setDeviceVolume(for: device.id, volume: $0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)

            Text("\(Int(volume * 100))%")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }

    private var volumeIcon: String {
        if volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}
