import AppKit
import CallRecorderCore
import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: menuBarIcon)
            if model.isCaptureActive {
                Text(duration(model.elapsedSeconds))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(menuBarAccessibilityLabel)
    }

    private var menuBarIcon: String {
        switch model.phase {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        default: "waveform"
        }
    }

    private var menuBarAccessibilityLabel: String {
        switch model.phase {
        case .recording: "Recording call"
        case .paused: "Call recording paused"
        default: "Call Recorder"
        }
    }
}

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingCancellation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .font(.headline)
                Spacer()
                if model.isCaptureActive {
                    Text(duration(model.elapsedSeconds))
                        .monospacedDigit()
                }
            }

            if model.isCaptureActive {
                if model.phase == .paused {
                    Label("Audio is not being recorded", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LevelRow(title: "System", value: model.captureStatistics.systemLevel)
                LevelRow(title: "Microphone", value: model.captureStatistics.microphoneLevel)
                if model.captureStatistics.summary.totalDroppedFrames > 0 {
                    Label(
                        "Dropped \(model.captureStatistics.summary.totalDroppedFrames) frames",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            }

            Picker("Microphone", selection: $model.selectedMicrophoneUID) {
                Text(model.automaticMicrophoneLabel)
                    .tag(AppModel.automaticMicrophoneUID)
                ForEach(model.microphones) { microphone in
                    Text(microphone.name).tag(microphone.uid)
                }
            }
            .disabled(model.isBusy)

            Picker("Language", selection: $model.language) {
                ForEach(RecordingLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy)

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = model.noticeMessage {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isCaptureActive {
                HStack {
                    Button {
                        if model.phase == .paused {
                            model.resumeRecording()
                        } else {
                            model.pauseRecording()
                        }
                    } label: {
                        Label(
                            model.phase == .paused ? "Resume" : "Pause",
                            systemImage: model.phase == .paused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }

                    Button {
                        model.stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .disabled(model.isCancelling)

                Button("Cancel Recording…", role: .destructive) {
                    isConfirmingCancellation = true
                }
                .frame(maxWidth: .infinity)
                .disabled(model.isCancelling)
            } else {
                Button {
                    model.startRecording()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(model.isBusy || model.selectedMicrophone == nil)
            }

            Button {
                model.chooseAudioForTranscription()
            } label: {
                Label("Transcribe Audio…", systemImage: "waveform.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.isBusy)

            Divider()
            HStack {
                Button("Recordings") {
                    showApplicationWindow(id: "recordings", title: "Recordings")
                }
                Button("Settings") {
                    showApplicationWindow(id: "settings", title: "Settings")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .disabled(model.isBusy)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            model.setMenuPresented(true)
            model.refreshMicrophones()
            model.reloadHistory()
        }
        .onDisappear { model.setMenuPresented(false) }
        .confirmationDialog(
            "Cancel this recording?",
            isPresented: $isConfirmingCancellation,
            titleVisibility: .visible
        ) {
            Button("Cancel and Delete Recording", role: .destructive) {
                model.cancelRecording()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The audio recorded in this session will be permanently deleted and will not be transcribed.")
        }
    }

    private var statusText: String {
        if model.isStarting { return "Starting…" }
        if model.isCancelling { return "Cancelling recording…" }
        return switch model.phase {
        case .idle: "Idle"
        case .recording: "Recording"
        case .paused: "Paused"
        case .processing: "Processing recording…"
        case .transcribing: "Transcribing with Deepgram…"
        case .complete: "Complete"
        case .failed: "Failed"
        }
    }

    private func showApplicationWindow(id: String, title: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        openWindow(id: id)
        DispatchQueue.main.async {
            application.activate(ignoringOtherApps: true)
            application.windows.first(where: { $0.title == title })?
                .makeKeyAndOrderFront(nil)
        }
    }

    private var statusColor: Color {
        if model.isStarting { return .orange }
        return switch model.phase {
        case .idle: .secondary
        case .recording: .red
        case .paused: .orange
        case .processing, .transcribing: .orange
        case .complete: .green
        case .failed: .red
        }
    }
}

private struct LevelRow: View {
    var title: String
    var value: Float

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .frame(width: 74, alignment: .leading)
            ProgressView(value: Double(max(0, min(value, 1))))
                .progressViewStyle(.linear)
        }
    }
}

private func duration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
}
