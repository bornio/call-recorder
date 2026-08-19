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
                if model.isRefreshingHistory {
                    ContentUnavailableView {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking Recordings…")
                        }
                    } description: {
                        Text("Checking Finder for recordings and transcripts.")
                    }
                } else {
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
                model.refreshHistoryFromFinder()
            } label: {
                if model.isRefreshingHistory {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking Finder for recording changes")
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(!model.canRefreshHistory)
            .help(model.historyRefreshUnavailableReason ?? "Check Finder for recording changes")

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
        .onAppear {
            model.setHistoryPresented(true)
            model.refreshHistoryFromFinder()
        }
        .onDisappear { model.setHistoryPresented(false) }
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
            deletionAlertTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { recording in
            Button(deletionActionTitle(for: recording), role: .destructive) {
                model.delete(recording)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { recording in
            if recording.effectiveOrigin == .importedAudio {
                Text("This removes the item and its private data from app history. Source audio and transcript files remain in Finder.")
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

    private var deletionAlertTitle: String {
        guard let pendingDeletion else { return "Delete recording?" }
        return pendingDeletion.effectiveOrigin == .importedAudio
            ? "Remove from history?"
            : "Delete recording?"
    }

    private func deletionActionTitle(for recording: RecordingManifest) -> String {
        recording.effectiveOrigin == .importedAudio
            ? "Remove from History"
            : "Delete Recording"
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
                Text(rowTitle)
                    .font(.headline)
                    .lineLimit(1)
                if recording.effectiveOrigin == .importedAudio {
                    Text("\(recording.displayTitle) · \(recording.language.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(statusSummary)
                    .font(.caption)
                    .foregroundStyle(statusIsFailure ? .red : .secondary)
                    .lineLimit(2)
                if let failure = recording.lastFailure {
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(failure.message)
                }
                if let captureHealthSummary = recording.captureHealthSummary {
                    Label(captureHealthSummary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(captureHealthSummary)
                }
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
                        Button(deletionMenuTitle, role: .destructive) {
                            pendingDeletion = recording
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More actions for \(rowTitle)")
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

    private var recoveryBytes: Int64 {
        model.recoveryBytes(for: recording)
    }

    private var rowTitle: String {
        guard recording.effectiveOrigin == .importedAudio else {
            return recording.displayTitle
        }
        guard let filename = recording.importedSourceFilename else {
            return "Imported audio"
        }
        return "Imported · \(filename)"
    }

    private var statusSummary: String {
        let audio = recording.audioStatusText(hasRecoveryAudio: recoveryBytes > 0)
        let transcript = recording.transcriptStatusText
        let language = recording.effectiveOrigin == .importedAudio
            ? ""
            : " · \(recording.language.displayName)"
        return "Audio: \(audio) · Transcript: \(transcript)\(language)"
    }

    private var hasNonDeleteActions: Bool {
        recording.files.audio != nil ||
            (recording.transcriptionStatus == .complete &&
                recording.files.transcriptMarkdown != nil)
    }

    private var hasMenuActions: Bool {
        hasNonDeleteActions || model.canDelete(recording)
    }

    private var deletionMenuTitle: String {
        recording.effectiveOrigin == .importedAudio
            ? "Remove from History…"
            : "Delete Recording…"
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
                .accessibilityLabel(
                    recording.captureStatus == .processing
                        ? "Finishing audio"
                        : "Transcribing"
                )
        } else if recording.captureHealthSummary != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Recording audio may need attention")
        } else if recording.transcriptionStatus == .complete {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
                .accessibilityLabel("Transcript ready")
        } else {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel(recording.transcriptStatusText)
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
