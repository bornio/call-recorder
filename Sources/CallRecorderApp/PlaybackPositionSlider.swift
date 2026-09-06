import AppKit
import Combine
import CallRecorderCore
import SwiftUI

struct PlaybackPositionSlider: NSViewRepresentable {
    @ObservedObject var player: RecordingAudioPlayerModel

    func makeNSView(context: Context) -> ReviewSlider {
        let slider = ReviewSlider()
        slider.isContinuous = true
        slider.target = slider
        slider.action = #selector(ReviewSlider.changed)
        slider.setAccessibilityLabel("Playback position")
        slider.player = player
        return slider
    }

    func updateNSView(_ slider: ReviewSlider, context: Context) {
        slider.player = player
        slider.minValue = 0
        slider.maxValue = max(player.duration, 1)
        slider.isEnabled = player.canSeek
        // AppKit owns the thumb during mouse tracking; the model owns all other positions.
        if !slider.trackingMouse { slider.doubleValue = player.displayTime }
        slider.setAccessibilityValueDescription(
            "\(formattedRecordingDuration(player.displayTime)) of \(formattedRecordingDuration(player.duration))"
        )
    }
}

@MainActor
final class ReviewSlider: NSSlider {
    weak var player: RecordingAudioPlayerModel?
    private(set) var trackingMouse = false
    private var closeObserver: AnyCancellable?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        closeObserver?.cancel()
        closeObserver = nil
        if let newWindow {
            closeObserver = NotificationCenter.default.publisher(
                for: NSWindow.willCloseNotification, object: newWindow
            ).sink { [weak player] _ in
                MainActor.assumeIsolated { player?.suspend() }
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        trackingMouse = true
        player?.beginScrubbing()
        super.mouseDown(with: event)
        trackingMouse = false
        player?.endScrubbing()
    }

    override func cancelOperation(_ sender: Any?) {
        player?.endScrubbing(cancelled: true)
    }

    @objc func changed() {
        if trackingMouse { player?.previewScrub(to: doubleValue) }
        else { player?.seek(to: doubleValue) }
    }
}
