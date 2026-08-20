@preconcurrency import AVFoundation
import CallRecorderCore
import SwiftUI

private struct RecordingAudioPlaybackSnapshot: Sendable {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
}

private actor RecordingAudioPlayerEngine {
    private var player: AVAudioPlayer?
    private var loadID: Int?

    func load(url: URL, id: Int) throws -> RecordingAudioPlaybackSnapshot {
        try Task.checkCancellation()

        let loadedPlayer = try AVAudioPlayer(contentsOf: url)
        loadedPlayer.prepareToPlay()

        try Task.checkCancellation()
        player?.stop()
        player = loadedPlayer
        loadID = id
        return snapshot(for: loadedPlayer)
    }

    func unload(ifLoadID id: Int) {
        guard loadID == id else { return }
        player?.stop()
        player = nil
        loadID = nil
    }

    func togglePlayback() -> RecordingAudioPlaybackSnapshot? {
        guard !Task.isCancelled, let player else { return nil }
        if player.isPlaying {
            player.pause()
        } else {
            if player.currentTime >= player.duration {
                player.currentTime = 0
            }
            player.play()
        }
        return snapshot(for: player)
    }

    func pause() -> RecordingAudioPlaybackSnapshot? {
        guard !Task.isCancelled, let player else { return nil }
        player.pause()
        return snapshot(for: player)
    }

    func seek(to time: TimeInterval) -> RecordingAudioPlaybackSnapshot? {
        guard !Task.isCancelled, let player else { return nil }
        player.currentTime = max(0, min(time, player.duration))
        return snapshot(for: player)
    }

    func setPan(_ pan: Float) {
        guard !Task.isCancelled else { return }
        player?.pan = max(-1, min(pan, 1))
    }

    func currentSnapshot() -> RecordingAudioPlaybackSnapshot? {
        player.map(snapshot(for:))
    }

    private func snapshot(for player: AVAudioPlayer) -> RecordingAudioPlaybackSnapshot {
        RecordingAudioPlaybackSnapshot(
            currentTime: player.currentTime,
            duration: player.duration,
            isPlaying: player.isPlaying
        )
    }
}

@MainActor
private final class RecordingAudioPlayerModel: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    private let url: URL
    private let engine = RecordingAudioPlayerEngine()
    private var isLoaded = false
    private var loadID = 0
    private var commandTask: Task<Void, Never>?
    private var panTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    deinit {
        commandTask?.cancel()
        panTask?.cancel()
        monitorTask?.cancel()
    }

    func load() async {
        guard !isLoaded, !isLoading || loadID == 0 else { return }

        loadID += 1
        let requestedLoadID = loadID
        isLoading = true
        errorMessage = nil

        do {
            let snapshot = try await engine.load(url: url, id: requestedLoadID)
            try Task.checkCancellation()
            guard requestedLoadID == loadID else {
                await engine.unload(ifLoadID: requestedLoadID)
                return
            }
            isLoaded = true
            isLoading = false
            apply(snapshot)
        } catch is CancellationError {
            await engine.unload(ifLoadID: requestedLoadID)
            if requestedLoadID == loadID {
                isLoading = false
            }
        } catch {
            await engine.unload(ifLoadID: requestedLoadID)
            guard requestedLoadID == loadID else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayback() {
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            guard let self,
                  let snapshot = await engine.togglePlayback(),
                  !Task.isCancelled else {
                return
            }
            apply(snapshot)
            if snapshot.isPlaying {
                startMonitoring()
            }
        }
    }

    func suspend() {
        if isLoading {
            loadID += 1
            isLoading = false
        }
        commandTask?.cancel()
        panTask?.cancel()
        monitorTask?.cancel()
        commandTask = Task { [weak self] in
            guard let self, let snapshot = await engine.pause() else { return }
            apply(snapshot)
        }
    }

    func seek(to time: TimeInterval) {
        let clampedTime = max(0, min(time, duration))
        currentTime = clampedTime
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            guard let self,
                  let snapshot = await engine.seek(to: clampedTime),
                  !Task.isCancelled else {
                return
            }
            apply(snapshot)
        }
    }

    func setPan(_ pan: Float) {
        panTask?.cancel()
        panTask = Task { [weak self] in
            guard let self else { return }
            await engine.setPan(pan)
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                guard let snapshot = await engine.currentSnapshot(),
                      !Task.isCancelled else {
                    return
                }
                apply(snapshot)
                if !snapshot.isPlaying { return }
            }
        }
    }

    private func apply(_ snapshot: RecordingAudioPlaybackSnapshot) {
        currentTime = snapshot.currentTime
        duration = snapshot.duration
        isPlaying = snapshot.isPlaying
    }
}

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
    @StateObject private var player: RecordingAudioPlayerModel
    @State private var channel: PlaybackChannel = .both
    let origin: RecordingOrigin

    init(url: URL, origin: RecordingOrigin) {
        _player = StateObject(wrappedValue: RecordingAudioPlayerModel(url: url))
        self.origin = origin
    }

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

                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 1)
                    )
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(
                        "\(formattedRecordingDuration(player.currentTime)) of \(formattedRecordingDuration(player.duration))"
                    )

                    Text("\(formattedRecordingDuration(player.currentTime)) / \(formattedRecordingDuration(player.duration))")
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
            }
        }
        .task { await player.load() }
        .onDisappear { player.suspend() }
    }
}
