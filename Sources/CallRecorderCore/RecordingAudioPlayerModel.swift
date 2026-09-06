@preconcurrency import AVFoundation
import Combine
import Foundation

private struct AudioPlaybackSnapshot: Sendable {
    let loadID: Int
    let revision: Int
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let hasEnded: Bool
}

private actor RecordingAudioPlayerEngine {
    private var player: AVAudioPlayer?
    private var loadID = 0
    private var revision = 0
    private var wasPlaying = false
    private var ended = false

    func load(url: URL, id: Int) throws -> AudioPlaybackSnapshot {
        try Task.checkCancellation()
        let loaded = try AVAudioPlayer(contentsOf: url)
        guard loaded.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        player?.stop()
        player = loaded
        loadID = id
        revision = 0
        wasPlaying = false
        ended = false
        return snapshot(for: loaded)
    }

    func unload(id: Int) {
        guard id == loadID else { return }
        player?.stop()
        player = nil
    }

    func command(load: Int, revision requested: Int, time: Double?, playing: Bool) throws -> AudioPlaybackSnapshot? {
        guard !Task.isCancelled, load == loadID, requested > revision, let player else { return nil }
        revision = requested
        if let time {
            player.currentTime = max(0, min(time, player.duration))
            ended = time >= player.duration
        }
        if playing, time == nil, ended { player.currentTime = 0; ended = false }
        if playing && !ended {
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            player.pause()
        }
        wasPlaying = player.isPlaying
        return snapshot(for: player)
    }

    func setPan(_ value: Float, load: Int) {
        guard !Task.isCancelled, load == loadID else { return }
        player?.pan = max(-1, min(value, 1))
    }

    func currentSnapshot() -> AudioPlaybackSnapshot? {
        guard let player else { return nil }
        if wasPlaying && !player.isPlaying { ended = true; wasPlaying = false }
        return snapshot(for: player)
    }

    private func snapshot(for player: AVAudioPlayer) -> AudioPlaybackSnapshot {
        AudioPlaybackSnapshot(
            loadID: loadID, revision: revision,
            currentTime: ended ? player.duration : player.currentTime,
            duration: player.duration, isPlaying: player.isPlaying, hasEnded: ended
        )
    }
}

/// A single recording's review transport. File decoding stays off the main actor;
/// UI commands carry a load identity and revision so stale work cannot win.
@MainActor
public final class RecordingAudioPlayerModel: ObservableObject {
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isLoading = true
    @Published public private(set) var hasEnded = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var previewTime: Double?
    @Published public private(set) var positionChangeID = 0
    @Published public private(set) var isPlaybackBlocked = false

    public var canSeek: Bool { isLoaded && !isLoading && errorMessage == nil && duration > 0 && !isPlaybackBlocked }
    public var displayTime: Double { previewTime ?? currentTime }

    private let engine = RecordingAudioPlayerEngine()
    private var loadedURL: URL?
    private var isLoaded = false
    private var loadID = 0
    private var revision = 0
    private var wantsPlayback = false
    private var pendingPosition: Double?
    private var pendingReveal = false
    private var scrubOrigin: (time: Double, playing: Bool)?
    private var commandTask: Task<Void, Never>?
    private var panTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    public init() {}

    deinit {
        commandTask?.cancel()
        panTask?.cancel()
        monitorTask?.cancel()
    }

    public func load(url: URL) async {
        if loadedURL == url, isLoaded || (isLoading && loadID > 0) { return }
        suspend()
        loadedURL = url
        isLoaded = false
        isLoading = true
        errorMessage = nil
        currentTime = 0
        duration = 0
        hasEnded = false
        pendingPosition = nil
        pendingReveal = false
        loadID += 1
        revision = 0
        let requested = loadID
        do {
            let snapshot = try await engine.load(url: url, id: requested)
            try Task.checkCancellation()
            guard loadID == requested else { await engine.unload(id: requested); return }
            isLoaded = true
            isLoading = false
            apply(snapshot)
        } catch {
            await engine.unload(id: requested)
            guard loadID == requested else { return }
            isLoading = false
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    public func togglePlayback() {
        guard canSeek, previewTime == nil else { return }
        wantsPlayback.toggle()
        perform(time: nil, reveal: wantsPlayback && hasEnded)
    }

    public func seek(to time: Double) {
        guard canSeek, time.isFinite else { return }
        scrubOrigin = nil
        previewTime = nil
        perform(time: bounded(time), reveal: true)
    }

    public func beginScrubbing() {
        guard canSeek, scrubOrigin == nil else { return }
        scrubOrigin = (currentTime, wantsPlayback)
        previewTime = currentTime
        wantsPlayback = false
        perform(time: nil, reveal: false, capturesScrubOrigin: true)
    }

    public func previewScrub(to time: Double) {
        guard canSeek, scrubOrigin != nil, time.isFinite else { return }
        previewTime = bounded(time)
    }

    public func endScrubbing(cancelled: Bool = false) {
        guard let origin = scrubOrigin, let previewTime else { return }
        scrubOrigin = nil
        self.previewTime = nil
        guard canSeek else { return }
        wantsPlayback = origin.playing
        perform(time: cancelled ? origin.time : previewTime, reveal: !cancelled)
    }

    public func setPlaybackBlocked(_ blocked: Bool) {
        isPlaybackBlocked = blocked
        if blocked { suspend() }
    }

    public func suspend() {
        scrubOrigin = nil
        previewTime = nil
        wantsPlayback = false
        isPlaying = false
        monitorTask?.cancel()
        panTask?.cancel()
        perform(time: nil, reveal: false)
    }

    public func setPan(_ pan: Float) {
        panTask?.cancel()
        let load = loadID
        panTask = Task { await engine.setPan(pan, load: load) }
    }

    private func bounded(_ time: Double) -> Double { max(0, min(time, duration)) }

    private func perform(time: Double?, reveal: Bool, capturesScrubOrigin: Bool = false) {
        guard isLoaded else { return }
        // Play/Pause can supersede a queued seek before the engine receives it.
        // Carry its target forward until the newest command is acknowledged.
        if let time { pendingPosition = time }
        pendingReveal = pendingReveal || reveal
        let target = pendingPosition
        revision += 1
        let requested = revision
        let load = loadID
        let playing = wantsPlayback
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let snapshot = try await engine.command(load: load, revision: requested, time: target, playing: playing),
                      !Task.isCancelled, load == loadID, requested == revision else { return }
                apply(snapshot)
                wantsPlayback = snapshot.isPlaying
                if capturesScrubOrigin, let origin = scrubOrigin {
                    scrubOrigin = (snapshot.currentTime, origin.playing)
                }
                if pendingReveal { positionChangeID += 1 }
                pendingPosition = nil
                pendingReveal = false
                if snapshot.isPlaying { startMonitoring() }
            } catch {
                guard !Task.isCancelled, load == loadID, requested == revision else { return }
                errorMessage = error.localizedDescription
                suspend()
            }
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled,
                      let snapshot = await engine.currentSnapshot(), !Task.isCancelled else { return }
                guard snapshot.loadID == loadID, snapshot.revision == revision else { continue }
                apply(snapshot)
                if !snapshot.isPlaying { wantsPlayback = false; return }
            }
        }
    }

    private func apply(_ snapshot: AudioPlaybackSnapshot) {
        guard snapshot.loadID == loadID, snapshot.revision == revision else { return }
        currentTime = snapshot.currentTime
        duration = snapshot.duration
        isPlaying = snapshot.isPlaying
        hasEnded = snapshot.hasEnded
    }
}
