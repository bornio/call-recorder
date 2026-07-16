import CallRecorderCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDeletion: RecordingManifest?
    @State private var pendingReupload: RecordingManifest?
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            if model.recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform")
                } description: {
                    Text("Finished calls and imported transcripts will appear here.")
                } actions: {
                    Button {
                        model.chooseAudioForTranscription()
                    } label: {
                        Label("Transcribe Audio…", systemImage: "waveform.badge.plus")
                    }
                    .disabled(!model.canImportAudio)
                    .help(model.importUnavailableReason ?? "Transcribe an audio file")
                    .accessibilityHint(model.importUnavailableReason ?? "Choose an audio file to transcribe")
                }
            } else {
                List(model.recordings) { recording in
                    RecordingRow(
                        recording: recording,
                        pendingDeletion: $pendingDeletion,
                        pendingReupload: $pendingReupload
                    )
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
                if model.isImportingAudio {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing audio…")
                    }
                } else {
                    Label("Transcribe Audio…", systemImage: "waveform.badge.plus")
                }
            }
            .disabled(!model.canImportAudio)
            .help(model.importUnavailableReason ?? "Transcribe an audio file")
            .accessibilityHint(model.importUnavailableReason ?? "Choose an audio file to transcribe")
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.transcribeDroppedAudio(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted && model.canImportAudio
        }
        .onAppear { model.refreshHistoryFromFinder() }
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
                Text("This removes the item from app history. Any source audio or transcript files remain in Finder.")
            } else {
                Text("This removes app history and permanently deletes Finder files only when Call Recorder can verify that it created them.")
            }
        }
        .alert(
            "Upload audio to Deepgram again?",
            isPresented: Binding(
                get: { pendingReupload != nil },
                set: { if !$0 { pendingReupload = nil } }
            ),
            presenting: pendingReupload
        ) { recording in
            Button("Upload Again", role: .destructive) {
                model.reuploadTranscription(for: recording)
                pendingReupload = nil
            }
            Button("Cancel", role: .cancel) { pendingReupload = nil }
        } message: { _ in
            Text("This starts a new paid Deepgram request. The prior request may already have been billed.")
        }
    }
}

private struct RecordingRow: View {
    @EnvironmentObject private var model: AppModel
    let recording: RecordingManifest
    @Binding var pendingDeletion: RecordingManifest?
    @Binding var pendingReupload: RecordingManifest?

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
                if let failure = recording.lastFailure {
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(failure.message)
                }
                let recoveryBytes = model.recoveryBytes(for: recording)
                if recoveryBytes > 0 {
                    Label(
                        "\(ByteCountFormatter.string(fromByteCount: recoveryBytes, countStyle: .file)) recovery audio retained",
                        systemImage: "internaldrive"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Private recovery audio is retained until saving succeeds or this history item is deleted.")
                }
            }

            Spacer(minLength: 12)

            if let duration = recording.durationSeconds {
                Text(shortDuration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Duration")
                    .accessibilityValue(accessibleDuration(duration))
            }

            if recording.transcriptionStatus == .waitingForCredential {
                SettingsLink {
                    Label("Add Key…", systemImage: "key.fill")
                }
            } else if model.shouldOfferFinalizationRecovery(for: recording) {
                Button(model.finalizationRecoveryEligibilityIsPending(for: recording)
                    ? "Checking Recovery…"
                    : "Retry Saving Audio") {
                    model.recoverFinalization(for: recording)
                }
                .disabled(!model.canRecoverFinalization(for: recording))
                .help(finalizationRetryHelp)
                .accessibilityHint(finalizationRetryHelp)
            } else if model.shouldOfferTranscriptionRetry(for: recording) {
                Button(retryButtonTitle) {
                    if model.transcriptionRetryEligibilityIsPending(for: recording) {
                        return
                    } else if model.transcriptionRetryIsLocal(for: recording) {
                        model.retryTranscription(for: recording)
                    } else {
                        pendingReupload = recording
                    }
                }
                .disabled(!model.canRetryTranscription(for: recording))
                .help(retryHelp)
                .accessibilityHint(retryHelp)
            } else if recording.files.transcriptMarkdown != nil,
                      recording.transcriptionStatus == .complete {
                Button("Reveal Transcript") {
                    model.revealTranscript(in: recording)
                }
            } else if recording.files.audio != nil {
                Button("Reveal Audio") {
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
                recording.files.transcriptMarkdown != nil)
    }

    private var hasMenuActions: Bool {
        hasNonDeleteActions || model.canDelete(recording)
    }

    private var retryHelp: String {
        if model.transcriptionRetryEligibilityIsPending(for: recording) {
            return "Checking whether the transcript can be recreated without another upload"
        }
        return model.retryUnavailableReason ?? (model.transcriptionRetryIsLocal(for: recording)
            ? "Recreate the transcript locally without another upload"
            : "Start another paid Deepgram upload")
    }

    private var retryButtonTitle: String {
        if model.transcriptionRetryEligibilityIsPending(for: recording) {
            return "Checking…"
        }
        return model.transcriptionRetryIsLocal(for: recording)
            ? "Recreate Transcript"
            : "Upload Again…"
    }

    private var finalizationRetryHelp: String {
        if model.finalizationRecoveryEligibilityIsPending(for: recording) {
            return "Checking whether the retained recovery audio can be saved"
        }
        return model.retryUnavailableReason ?? "Retry saving audio"
    }
}

private struct RecordingStatusSymbol: View {
    let recording: RecordingManifest

    var body: some View {
        if recording.transcriptionStatus == .waitingForCredential {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Deepgram key needed")
        } else if recording.lastFailure != nil ||
                    recording.captureStatus == .failed ||
                    recording.transcriptionStatus == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Needs attention")
        } else if recording.captureStatus == .processing ||
                    recording.transcriptionStatus == .transcribing {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(recording.statusText)
        } else if recording.transcriptionStatus == .complete {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
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
