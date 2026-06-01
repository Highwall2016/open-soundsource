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
