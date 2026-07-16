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
        case .stopping: "Saving recording, elapsed \(elapsed)"
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

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.isPreparingToTerminate {
                TerminationContent(model: model)
            } else {
                captureContent
            }

            if let issue = model.captureIssue {
                CaptureIssueView(model: model, issue: issue)
            }

            if let recording = model.backgroundSummaryRecording {
                Divider()
                BackgroundRecordingSummary(
                    recording: recording,
                    captureIsActive: model.captureState != .ready,
                    activity: model.backgroundActivity,
                    action: showRecordings
                )
            }

            Divider()
            HStack(spacing: 8) {
                Button { showRecordings() } label: {
                    Label("Recordings", systemImage: "tray.full")
                }
                .buttonStyle(.bordered)
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.bordered)
                .disabled(model.isPreparingToTerminate)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            model.setMenuPresented(true)
            model.refreshMicrophones()
            model.reloadHistory()
        }
        .onDisappear { model.setMenuPresented(false) }
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
                discardAction: confirmDiscard
            )
        case .paused:
            ActiveCaptureContent(
                model: model,
                isPaused: true,
                discardAction: confirmDiscard
            )
        case .stopping:
            CaptureTransitionContent(
                title: model.isCancelling ? "Discarding recording…" : "Saving recording…",
                detail: model.isCancelling
                    ? "Stopping capture and removing this session."
                    : "Closing capture safely. You can start another recording as soon as this finishes.",
                systemImage: "ellipsis.circle",
                elapsedSeconds: model.elapsedSeconds
            )
        }
    }

    private func showRecordings() {
        openWindow(id: "recordings")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func confirmDiscard() {
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "The audio recorded in this session will be permanently deleted and will not be transcribed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Discard Recording").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        model.cancelRecording()
    }
}

private struct TerminationContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        CaptureTransitionContent(
            title: model.captureState == .stopping
                ? "Saving recording, then quitting…"
                : "Finishing transcription, then quitting…",
            detail: "Call Recorder will quit automatically when it is safe.",
            systemImage: "power"
        )
    }
}

private struct CaptureIssueView: View {
    let model: AppModel
    let issue: CaptureIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            switch issue.recovery {
            case .appSettings:
                SettingsLink {
                    Label("Review Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .microphoneSettings:
                Button("Open Microphone Settings") {
                    model.openMicrophonePrivacySettings()
                }
                .controlSize(.small)
            case .systemAudioSettings:
                Button("Open System Audio Settings") {
                    model.openSystemAudioPrivacySettings()
                }
                .controlSize(.small)
            case nil:
                EmptyView()
            }
        }
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

            if !model.hasDeepgramKey,
               model.backgroundSummaryRecording?.transcriptionStatus != .waitingForCredential {
                HStack(spacing: 8) {
                    Label("Transcripts need a Deepgram key", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink {
                        Text("Add Key…")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if model.selectedMicrophone == nil {
                Label(
                    "No microphone detected. Connect one, then reopen this menu.",
                    systemImage: "mic.slash"
                )
                .font(.caption)
                .foregroundStyle(.orange)
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
            .keyboardShortcut(.defaultAction)
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
                        : "Recording locally. Transcription starts after you stop."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
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
            .opacity(isPaused ? 0.4 : 1)
            .accessibilityHidden(isPaused)

            HStack {
                Button {
                    if isPaused {
                        model.resumeRecording()
                    } else {
                        model.pauseRecording()
                    }
                } label: {
                    Label(
                        isPaused ? "Resume" : "Pause",
                        systemImage: isPaused ? "play.fill" : "pause.fill"
                    )
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

            Button("Discard Recording…", role: .destructive, action: discardAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
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
    let activity: RecordingJobActivity?
    let action: () -> Void

    var body: some View {
        Group {
            if recording.transcriptionStatus == .waitingForCredential {
                SettingsLink {
                    summaryLabel
                }
                .accessibilityHint("Opens Settings to add a Deepgram key")
            } else {
                Button(action: action) {
                    summaryLabel
                }
                .accessibilityHint("Opens Recordings")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var summaryLabel: some View {
        HStack(alignment: .center, spacing: 10) {
            statusIcon
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(captureIsActive ? "Previous recording" : "Recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: recording.transcriptionStatus == .waitingForCredential
                ? "gearshape"
                : "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        if recording.transcriptionStatus == .waitingForCredential {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
        } else if recording.lastFailure != nil ||
                    recording.captureStatus == .failed ||
                    recording.transcriptionStatus == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if activeActivity != nil ||
                    recording.captureStatus == .processing ||
                    recording.transcriptionStatus == .transcribing {
            ProgressView()
                .controlSize(.small)
        } else if recording.transcriptionStatus == .complete {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if recording.transcriptionStatus == .waitingForCredential {
            return "Deepgram key needed"
        }
        if recording.lastFailure != nil ||
            recording.captureStatus == .failed ||
            recording.transcriptionStatus == .failed {
            return "Recording needs attention"
        }
        if case .finishingAudio = activeActivity {
            return "Audio secured locally"
        }
        if case .transcribing = activeActivity {
            return "Saved locally · Transcribing…"
        }
        if recording.captureStatus == .processing {
            return "Audio secured locally"
        }
        if recording.transcriptionStatus == .transcribing {
            return "Saved locally · Transcribing…"
        }
        if recording.captureStatus == .complete,
           recording.transcriptionStatus == .notStarted {
            return "Saved locally · Waiting to transcribe"
        }
        return "Transcript ready"
    }

    private var detail: String {
        if recording.transcriptionStatus == .waitingForCredential {
            return "Add a key to start transcription."
        }
        if recording.lastFailure != nil ||
            recording.captureStatus == .failed ||
            recording.transcriptionStatus == .failed {
            return "Open Recordings for details."
        }
        if case .finishingAudio = activeActivity {
            return "Finishing the audio file. You can record again."
        }
        if case .transcribing = activeActivity {
            return "You can start another recording."
        }
        if recording.captureStatus == .processing {
            return "Finishing the audio file. You can record again."
        }
        if recording.transcriptionStatus == .transcribing {
            return "You can start another recording."
        }
        if captureIsActive && recording.transcriptionStatus == .notStarted {
            return "Transcription starts when this recording ends."
        }
        return recording.displayTitle
    }

    private var activeActivity: RecordingJobActivity? {
        guard activity?.recordingID == recording.id else { return nil }
        return activity
    }
}

private func recordingDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3_600 {
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
