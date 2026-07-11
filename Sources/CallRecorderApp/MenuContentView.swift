import AppKit
import CallRecorderCore
import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.phase == .recording ? "record.circle.fill" : "waveform")
            if model.phase == .recording {
                Text(duration(model.elapsedSeconds))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(model.phase == .recording ? "Recording call" : "Call Recorder")
    }
}

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .font(.headline)
                Spacer()
                if model.phase == .recording {
                    Text(duration(model.elapsedSeconds))
                        .monospacedDigit()
                }
            }

            if model.phase == .recording {
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

            if model.phase == .recording {
                Button(role: .destructive) {
                    model.stopRecording()
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
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
    }

    private var statusText: String {
        if model.isStarting { return "Starting…" }
        return switch model.phase {
        case .idle: "Idle"
        case .recording: "Recording"
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
