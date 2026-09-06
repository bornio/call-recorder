import AppKit
import CallRecorderCore
import SwiftUI

private enum PlaybackChannel: String, CaseIterable, Identifiable {
    case both
    case left
    case right

    var id: String { rawValue }

    var pan: Float {
        switch self {
        case .both: 0
        case .left: -1
        case .right: 1
        }
    }
}

struct RecordingAudioPlayer: View {
    @ObservedObject var player: RecordingAudioPlayerModel
    @State private var channel: PlaybackChannel = .both
    let url: URL
    let origin: RecordingOrigin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if player.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading audio…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 32)
                .accessibilityElement(children: .combine)
            } else if let errorMessage = player.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 12) {
                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    .disabled(!player.canSeek || player.previewTime != nil)

                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)

                    PlaybackPositionSlider(player: player)
                        .frame(minWidth: 60)
                        .accessibilityLabel("Playback position")

                    Text("\(formattedRecordingDuration(player.displayTime)) / \(formattedRecordingDuration(player.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 88, alignment: .trailing)

                    Picker("Channels", selection: $channel) {
                        Text("Both channels").tag(PlaybackChannel.both)
                        Text(origin == .nativeRecording ? "Mac audio" : "Left channel")
                            .tag(PlaybackChannel.left)
                        Text(origin == .nativeRecording ? "You" : "Right channel")
                            .tag(PlaybackChannel.right)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: channel) { _, channel in
                        player.setPan(channel.pan)
                    }
                }
                if player.isPlaybackBlocked {
                    Text("Review playback is paused during recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await player.load(url: url) }
        .onDisappear { player.suspend() }
    }
}
