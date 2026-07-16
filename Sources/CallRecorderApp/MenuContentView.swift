import AppKit
import CallRecorderCore
import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: menuBarIcon)
            if model.isCaptureActive || model.captureState == .stopping {
                Text(recordingDuration(model.elapsedSeconds))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var menuBarIcon: String {
        switch model.captureState {
        case .starting: "ellipsis.circle"
        case .recording, .stopping: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .ready:
            model.captureErrorMessage == nil ? "waveform" : "exclamationmark.triangle"
        }
    }

    private var accessibilityLabel: String {
        let elapsed = accessibleDuration(model.elapsedSeconds)
        return switch model.captureState {
        case .ready:
            model.captureErrorMessage == nil
                ? "Call Recorder, ready"
                : "Call Recorder, recording error"
        case .starting: "Call Recorder, starting recording"
        case .recording: "Recording, elapsed \(elapsed)"
        case .paused: "Recording paused, elapsed \(elapsed)"
        case .stopping: "Recording stopping, elapsed \(elapsed)"
        }
    }
}

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            captureContent

            if let error = model.captureErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }

            if let recording = model.backgroundSummaryRecording {
                Divider()
                BackgroundRecordingSummary(
                    recording: recording,
                    captureIsActive: model.captureState != .ready,
                    action: showRecordings
                )
            }

            Divider()
            HStack {
                Button("Recordings") { showRecordings() }
                    .buttonStyle(.plain)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .help("Settings")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            model.setMenuPresented(true)
            model.refreshMicrophones()
            model.reloadHistory()
        }
        .onDisappear { model.setMenuPresented(false) }
        .alert("Discard this recording?", isPresented: $isConfirmingDiscard) {
            Button("Discard Recording", role: .destructive) {
                model.cancelRecording()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The audio recorded in this session will be permanently deleted and will not be transcribed.")
        }
    }

    @ViewBuilder
    private var captureContent: some View {
        switch model.captureState {
        case .ready:
            ReadyCaptureContent(model: model)
        case .starting:
            CaptureTransitionContent(
                title: "Starting recording…",
                detail: "Checking your microphone and Mac audio.",
                systemImage: "ellipsis.circle"
            )
        case .recording:
            ActiveCaptureContent(
                model: model,
                isPaused: false,
                discardAction: { isConfirmingDiscard = true }
            )
        case .paused:
            ActiveCaptureContent(
                model: model,
                isPaused: true,
                discardAction: { isConfirmingDiscard = true }
            )
        case .stopping:
            CaptureTransitionContent(
                title: model.isCancelling ? "Discarding recording…" : "Securing audio locally…",
                detail: model.isCancelling
                    ? "Stopping capture and removing this session."
                    : "The next recording will be available as soon as capture closes.",
                systemImage: "record.circle.fill",
                elapsedSeconds: model.elapsedSeconds
            )
        }
    }

    private func showRecordings() {
        openWindow(id: "recordings")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct ReadyCaptureContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Ready to record", systemImage: "waveform")
                    .font(.headline)
                Text("Mac audio and your microphone will be saved locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Microphone") {
                Picker("Microphone", selection: $model.selectedMicrophoneUID) {
                    Text(model.automaticMicrophoneLabel)
                        .tag(AppModel.automaticMicrophoneUID)
                    ForEach(model.microphones) { microphone in
                        Text(microphone.name).tag(microphone.uid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .trailing)
            }

            LabeledContent("Language") {
                Picker("Language", selection: $model.language) {
                    ForEach(RecordingLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Button {
                model.startRecording()
            } label: {
                Label(
                    model.pendingRecordingCount > 0 ? "Start Next Recording" : "Start Recording",
                    systemImage: "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canStartRecording)
        }
    }
}

private struct ActiveCaptureContent: View {
    @ObservedObject var model: AppModel
    let isPaused: Bool
    let discardAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label {
                        Text(isPaused ? "Paused" : "Recording")
                    } icon: {
                        Image(systemName: isPaused ? "pause.circle.fill" : "record.circle.fill")
                            .foregroundStyle(isPaused ? .orange : .red)
                    }
                    .font(.headline)
                    Spacer()
                    Text(recordingDuration(model.elapsedSeconds))
                        .font(.headline.monospacedDigit())
                        .accessibilityLabel("Elapsed recording time")
                        .accessibilityValue(accessibleDuration(model.elapsedSeconds))
                }
                Text(
                    isPaused
                        ? "No audio is being recorded."
                        : "This call stays local until you stop"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !isPaused {
                CaptureLevelRow(title: "Mac audio", value: model.captureStatistics.systemLevel)
                CaptureLevelRow(title: "You", value: model.captureStatistics.microphoneLevel)
                if let microphone = model.selectedMicrophone?.name {
                    Text(microphone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.captureStatistics.summary.totalDroppedFrames > 0 {
                    Label("Audio may contain gaps", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if isPaused {
                Button {
                    model.resumeRecording()
                } label: {
                    Label("Resume Recording", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop & Save", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                HStack {
                    Button {
                        model.pauseRecording()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.stopRecording()
                    } label: {
                        Label("Stop & Save", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }

            Button("Discard Recording…", role: .destructive, action: discardAction)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct CaptureTransitionContent: View {
    let title: String
    let detail: String
    let systemImage: String
    var elapsedSeconds: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                if let elapsedSeconds {
                    Text(recordingDuration(elapsedSeconds))
                        .font(.headline.monospacedDigit())
                        .accessibilityLabel("Elapsed recording time")
                        .accessibilityValue(accessibleDuration(elapsedSeconds))
                }
            }
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CaptureLevelRow: View {
    let title: String
    let value: Float

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .frame(width: 72, alignment: .leading)
            ProgressView(value: clampedValue)
                .progressViewStyle(.linear)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) level")
        .accessibilityValue("\(Int((clampedValue * 100).rounded())) percent")
    }

    private var clampedValue: Double {
        Double(max(0, min(value, 1)))
    }
}

private struct BackgroundRecordingSummary: View {
    let recording: RecordingManifest
    let captureIsActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(detail)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if recording.captureStatus == .processing ||
            recording.transcriptionStatus == .transcribing {
            ProgressView()
                .controlSize(.small)
        } else if recording.lastFailure != nil {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if recording.transcriptionStatus == .complete {
            Image(systemName: "checkmark.circle")
        } else {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if recording.captureStatus == .processing {
            return "Background · Finishing audio…"
        }
        if recording.transcriptionStatus == .transcribing {
            return "Background · Transcribing…"
        }
        if recording.captureStatus == .complete,
           recording.transcriptionStatus == .notStarted {
            return captureIsActive
                ? "Background · Waiting for current recording to end"
                : "Background · Waiting to transcribe"
        }
        if recording.transcriptionStatus == .waitingForCredential {
            return "Background · Needs Deepgram key"
        }
        if recording.lastFailure != nil {
            return "Background · Needs attention"
        }
        return "Background · Transcript ready"
    }

    private var detail: String {
        if recording.captureStatus == .processing {
            return "Audio is secured locally"
        }
        if recording.transcriptionStatus == .transcribing {
            return "Audio already saved"
        }
        if captureIsActive && recording.transcriptionStatus == .notStarted {
            return "Transcription will start afterward"
        }
        if let failure = recording.lastFailure {
            return failure.stage == .transcription
                ? "Audio saved · Retry available"
                : "Recorded audio was preserved"
        }
        return recording.displayTitle
    }
}

private func recordingDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3_600 {
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}

private func accessibleDuration(_ interval: TimeInterval) -> String {
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
