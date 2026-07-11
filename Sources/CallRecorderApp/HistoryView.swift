import CallRecorderCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDeletion: RecordingManifest?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform.badge.plus")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribe an audio file")
                        .font(.headline)
                    Text("Drop audio here or choose a file. The transcript is saved beside it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Audio…") { model.chooseAudioForTranscription() }
                    .disabled(model.isBusy)
            }
            .padding(12)
            .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            .dropDestination(for: URL.self) { urls, _ in
                model.transcribeDroppedAudio(urls)
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }

            Divider()

            Group {
                if model.recordings.isEmpty {
                    ContentUnavailableView(
                        "No Recordings",
                        systemImage: "waveform",
                        description: Text("Completed and failed recordings will appear here.")
                    )
                } else {
                    List(model.recordings) { recording in
                        RecordingRow(recording: recording, pendingDeletion: $pendingDeletion)
                            .environmentObject(model)
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .toolbar {
            Button {
                model.reloadHistory()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .onAppear { model.reloadHistory() }
        .alert(
            "Delete recording?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { recording in
            Button("Delete", role: .destructive) {
                model.delete(recording)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { recording in
            if recording.effectiveOrigin == .importedAudio {
                Text("This removes the item from app history. The source audio and transcript remain in Finder.")
            } else {
                Text("This permanently removes the app-created Audio.m4a and Transcript.md files.")
            }
        }
    }
}

private struct RecordingRow: View {
    @EnvironmentObject private var model: AppModel
    let recording: RecordingManifest
    @Binding var pendingDeletion: RecordingManifest?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.displayTitle)
                        .font(.headline)
                    Text("\(recording.statusText) · \(recording.language.displayName) · \(recording.microphoneName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let duration = recording.durationSeconds {
                    Text(shortDuration(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let failure = recording.lastFailure {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            ForEach(recording.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Reveal Audio") {
                    model.revealAudio(in: recording)
                }
                .disabled(recording.files.audio == nil)

                Button("Reveal Transcript") {
                    model.revealTranscript(in: recording)
                }
                .disabled(
                    recording.transcriptionStatus != .complete ||
                        recording.files.transcriptMarkdown == nil
                )

                Button("Retry Transcription") {
                    model.retryTranscription(for: recording)
                }
                .disabled(model.isBusy || !TranscriptionRetryPolicy.canRetry(recording))

                Button("Recover Recording") {
                    model.recoverFinalization(for: recording)
                }
                .disabled(model.isBusy || !FinalizationRecoveryPolicy.canRecover(recording))

                Spacer()
                Button("Delete", role: .destructive) {
                    pendingDeletion = recording
                }
                .disabled(model.isBusy)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }
}

private func shortDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
}
