import AppKit
import CallRecorderCore
import SwiftUI

struct MenuBarLabelView: View {
    let appDelegate: AppDelegate
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var didOpenLaunchWindow = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: menuBarIcon)
            if model.isCaptureActive || model.captureState == .stopping {
                Text(formattedRecordingDuration(model.elapsedSeconds))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .task {
            appDelegate.showRecorder = {
                openWindow(id: "recorder")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            guard !didOpenLaunchWindow else { return }
            didOpenLaunchWindow = true
            #if CALL_RECORDER_KEYCHAIN_FREE_DEV
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--open-recordings") {
                openWindow(id: "recordings")
                NSApplication.shared.activate(ignoringOtherApps: true)
                return
            } else if arguments.contains("--open-settings") {
                openSettings()
                return
            }
            #endif
            appDelegate.showRecorder?()
        }
    }

    private var menuBarIcon: String {
        switch model.captureState {
        case .starting: "ellipsis.circle"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .stopping: "ellipsis.circle"
        case .ready: readyMenuBarIcon
        }
    }

    private var readyMenuBarIcon: String {
        if model.captureIssue != nil || backgroundNeedsAttention {
            return "exclamationmark.triangle"
        }
        if model.isPreparingToTerminate || model.backgroundActivity != nil {
            return "ellipsis.circle"
        }
        if model.hasUnseenTranscriptCompletion {
            return "checkmark.circle"
        }
        return "waveform"
    }

    private var accessibilityLabel: String {
        let elapsed = accessibleDuration(model.elapsedSeconds)
        return switch model.captureState {
        case .ready:
            readyAccessibilityLabel
        case .starting: "Call Recorder, starting recording"
        case .recording: "Recording, elapsed \(elapsed)"
        case .paused: "Recording paused, elapsed \(elapsed)"
        case .stopping:
            model.isCancelling
                ? "Discarding recording, elapsed \(elapsed)"
                : "Saving recording, elapsed \(elapsed)"
        }
    }

    private var readyAccessibilityLabel: String {
        if model.captureIssue != nil {
            return "Call Recorder, recording needs attention"
        }
        if backgroundNeedsAttention {
            return "Call Recorder, previous recording needs attention"
        }
        if model.isPreparingToTerminate {
            return "Call Recorder, finishing work before quitting"
        }
        if let activity = model.backgroundActivity {
            return switch activity {
            case .finishingAudio: "Call Recorder, saving previous recording"
            case .transcribing: "Call Recorder, transcribing previous recording"
            }
        }
        if model.hasUnseenTranscriptCompletion {
            return "Call Recorder, transcript ready"
        }
        return "Call Recorder, ready"
    }

    private var backgroundNeedsAttention: Bool {
        model.hasRecordingNeedingAttention
    }
}

func accessibleDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    let hours = seconds / 3_600
    let minutes = (seconds / 60) % 60
    let remainder = seconds % 60
    return [
        hours > 0 ? "\(hours) hours" : nil,
        minutes > 0 ? "\(minutes) minutes" : nil,
        "\(remainder) seconds",
    ].compactMap { $0 }.joined(separator: ", ")
}
