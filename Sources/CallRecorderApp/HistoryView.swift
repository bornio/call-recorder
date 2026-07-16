import CallRecorderCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDeletion: RecordingManifest?
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            if model.recordings.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform",
                    description: Text("Finished calls and imported transcripts will appear here.")
                )
            } else {
                List(model.recordings) { recording in
                    RecordingRow(recording: recording, pendingDeletion: $pendingDeletion)
                        .environmentObject(model)
                }
                .listStyle(.inset)
            }

            if isDropTargeted {
                ContentUnavailableView(
                    "Transcribe File",
                    systemImage: "waveform.badge.plus",
                    description: Text("Drop the file to queue a transcript beside it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle("Recordings")
        .frame(minWidth: 620)
        .toolbar {
            Button {
                model.chooseAudioForTranscription()
            } label: {
                Label("Transcribe File…", systemImage: "waveform.badge.plus")
            }
            .disabled(!model.canImportAudio)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.transcribeDroppedAudio(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted && model.canImportAudio
        }
        .onAppear { model.reloadHistory() }
        .alert(
            "Unable to complete action",
            isPresented: Binding(
                get: { model.historyErrorMessage != nil },
                set: { if !$0 { model.historyErrorMessage = nil } }
            )
        ) {
            Button("OK") { model.historyErrorMessage = nil }
        } message: {
            Text(model.historyErrorMessage ?? "Unknown error")
        }
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
        HStack(alignment: .center, spacing: 10) {
            RecordingStatusSymbol(recording: recording)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(recording.statusText) · \(recording.language.displayName)")
                    .font(.caption)
                    .foregroundStyle(statusIsFailure ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let duration = recording.durationSeconds {
                Text(shortDuration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.shouldOfferTranscriptionRetry(for: recording),
               recording.transcriptionStatus == .failed {
                Button("Retry") {
                    model.retryTranscription(for: recording)
                }
                .disabled(!model.canRetryTranscription(for: recording))
                .help(retryHelp)
                .accessibilityHint(retryHelp)
            } else if recording.files.transcriptMarkdown != nil,
                      recording.transcriptionStatus == .complete {
                Button("Show in Finder") {
                    model.revealTranscript(in: recording)
                }
            } else if recording.files.audio != nil {
                Button("Show in Finder") {
                    model.revealAudio(in: recording)
                }
            }

            if hasMenuActions {
                Menu {
                    if recording.files.audio != nil {
                        Button("Reveal Audio") { model.revealAudio(in: recording) }
                    }
                    if recording.transcriptionStatus == .complete,
                       recording.files.transcriptMarkdown != nil {
                        Button("Reveal Transcript") { model.revealTranscript(in: recording) }
                    }
                    if model.shouldOfferTranscriptionRetry(for: recording) {
                        Button(retryMenuTitle) {
                            model.retryTranscription(for: recording)
                        }
                        .disabled(!model.canRetryTranscription(for: recording))
                        .help(retryHelp)
                    }
                    if model.canRecoverFinalization(for: recording) {
                        Button("Finish Saving Audio") {
                            model.recoverFinalization(for: recording)
                        }
                    }
                    if model.canDelete(recording) {
                        if hasNonDeleteActions {
                            Divider()
                        }
                        Button("Delete", role: .destructive) {
                            pendingDeletion = recording
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More actions for \(recording.displayTitle)")
                .help("More actions")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private var statusIsFailure: Bool {
        recording.lastFailure != nil ||
            recording.captureStatus == .failed ||
            recording.transcriptionStatus == .failed
    }

    private var hasNonDeleteActions: Bool {
        recording.files.audio != nil ||
            (recording.transcriptionStatus == .complete &&
                recording.files.transcriptMarkdown != nil) ||
            model.shouldOfferTranscriptionRetry(for: recording) ||
            model.canRecoverFinalization(for: recording)
    }

    private var hasMenuActions: Bool {
        hasNonDeleteActions || model.canDelete(recording)
    }

    private var retryHelp: String {
        model.transcriptionRetryUnavailableReason ?? "Retry transcription"
    }

    private var retryMenuTitle: String {
        guard let reason = model.transcriptionRetryUnavailableReason else {
            return "Retry Transcription"
        }
        return "Retry Transcription — \(reason)"
    }
}

private struct RecordingStatusSymbol: View {
    let recording: RecordingManifest

    var body: some View {
        if recording.captureStatus == .processing ||
            recording.transcriptionStatus == .transcribing {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(recording.statusText)
        } else if recording.lastFailure != nil ||
                    recording.captureStatus == .failed ||
                    recording.transcriptionStatus == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Needs attention")
        } else if recording.transcriptionStatus == .complete {
            Image(systemName: "checkmark.circle")
                .accessibilityLabel("Transcript ready")
        } else {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel(recording.statusText)
        }
    }
}

private func shortDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded()))
    if seconds >= 3_600 {
        return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
