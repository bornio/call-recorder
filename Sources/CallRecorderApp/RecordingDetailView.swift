import CallRecorderCore
import Foundation
import SwiftUI

struct RecordingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let recording: RecordingManifest
    let searchText: String
    let searchMatches: [TranscriptSearchMatch]
    let selectedSearchMatchIndex: Int
    let searchNavigationID: Int
    let searchNavigation: RecordingSearchNavigation?
    @Binding var selectedSection: RecordingDetailSection
    let deleteAction: () -> Void
    let reuploadAction: () -> Void

    @State private var titleDraft = ""
    @State private var isEditingTitle = false
    @State private var titleSaveErrorMessage: String?
    @State private var renameTarget: SpeakerRenameTarget?
    @State private var speakerNameDraft = ""
    @StateObject private var audioPlayer = RecordingAudioPlayerModel()
    @StateObject private var reading = TranscriptReadingState()
    @FocusState private var titleIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 16)

            Divider()

            if let audioURL = model.resolvedAudioURL(for: recording) {
                RecordingAudioPlayer(player: audioPlayer, url: audioURL, origin: recording.effectiveOrigin)
                    .id(audioURL)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)

                Divider()
            }

            Picker("Recording details", selection: $selectedSection) {
                Text("Transcript").tag(RecordingDetailSection.transcript)
                Text("Info").tag(RecordingDetailSection.info)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch selectedSection {
                case .transcript:
                    transcriptContent
                case .info:
                    infoContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .onAppear {
            resetTitleEditor()
            if !searchText.isEmpty { reading.suspendFollowing() }
            model.ensureTranscriptLoaded(for: recording)
            model.refreshMeetingChoices(for: recording)
        }
        .onDisappear { audioPlayer.suspend() }
        .onChange(of: model.captureState, initial: true) { _, state in
            audioPlayer.setPlaybackBlocked(state != .ready)
        }
        .onChange(of: model.historySearchText) { _, _ in reading.suspendFollowing() }
        .onChange(of: searchNavigationID) { _, _ in reading.suspendFollowing() }
        .onChange(of: recording.title) { _, _ in
            if !isEditingTitle {
                titleDraft = recording.displayTitle
                titleSaveErrorMessage = nil
            }
        }
        .alert(
            "Rename speaker",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Speaker name", text: $speakerNameDraft)
            Button("Save") {
                if let renameTarget {
                    model.renameSpeaker(
                        in: recording,
                        channel: renameTarget.channel,
                        speaker: renameTarget.speaker,
                        to: speakerNameDraft
                    )
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Saving updates this speaker’s name in Call Recorder and the Markdown transcript. Files edited outside the app are preserved; use Export Transcript… to save a corrected copy.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleEditor

            if let titleSaveErrorMessage {
                Label(titleSaveErrorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Could not save recording title: \(titleSaveErrorMessage)")
            }

            HStack(spacing: 8) {
                Text(recordedDate(recording.effectiveStartedAt, detail: false))
                if let duration = recording.durationSeconds {
                    Text("·")
                    Text(formattedRecordingDuration(duration))
                }
                Text("·")
                Text(recording.language.displayName)
                Text("·")
                StatusLabel(recording: recording)
                Spacer()
                MeetingAssociationMenu(recording: recording, willEdit: reading.suspendFollowing)
                    .environmentObject(model)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var titleEditor: some View {
        HStack(alignment: .center, spacing: 8) {
            if isEditingTitle {
                TextField("Recording title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.title.bold())
                    .focused($titleIsFocused)
                    .onSubmit { saveTitle() }
                    .onExitCommand { resetTitleEditor() }
                    .disabled(!model.canEditMetadata(for: recording))
                    .accessibilityLabel("Recording title")

                Button(action: saveTitle) {
                    Label("Save title", systemImage: "checkmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasTitleChanges || !model.canEditMetadata(for: recording))
                .help("Save title")

                Button(action: resetTitleEditor) {
                    Label("Cancel editing title", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .help("Cancel")
            } else {
                Text(recording.displayTitle)
                    .font(.title.bold())
                    .lineLimit(2)
                    .textSelection(.enabled)

                Button(action: beginTitleEditing) {
                    Label("Rename recording", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!model.canEditMetadata(for: recording))
                .help("Rename recording")

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if let document = model.transcriptDocument(for: recording),
           !document.segments.isEmpty {
            VStack(spacing: 0) {
                if !normalizedSearch.isEmpty {
                    HStack(spacing: 10) {
                        Text(searchMatchSummary)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(searchMatchAccessibilityLabel)
                        Spacer()
                        ControlGroup {
                            Button(action: { searchNavigation?.previous() }) {
                                Label("Previous match", systemImage: "chevron.up")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Previous match (⇧⌘G)")

                            Button(action: { searchNavigation?.next() }) {
                                Label("Next match", systemImage: "chevron.down")
                                    .labelStyle(.iconOnly)
                            }
                            .help("Next match (Return or ⌘G)")
                        }
                        .controlSize(.small)
                        .disabled(searchNavigation?.canNavigate != true)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                    Divider()
                }

                HStack {
                    Toggle(isOn: $reading.followsAudio) {
                        Label(reading.followsAudio ? "Following audio" : "Follow audio", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .toggleStyle(.button)
                    .disabled(audioPlayer.isLoading || audioPlayer.errorMessage != nil || audioPlayer.duration <= 0)
                    .help("Keep the current sentence visible. Scrolling, selection, and search stop following.")
                    Spacer()
                    if audioPlayer.previewTime != nil {
                        Label("Preview · \(formattedRecordingDuration(audioPlayer.displayTime))", systemImage: "hand.draw")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Audio · \(formattedRecordingDuration(audioPlayer.currentTime))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 28)
                .padding(.vertical, 8)

                TranscriptTextView(
                    document: document, recording: recording, player: audioPlayer, reading: reading,
                    searchMatches: searchMatches, activeMatch: activeSearchMatch,
                    searchNavigationID: searchNavigationID, rename: beginRename
                )
            }
        } else if model.transcriptIsLoading(for: recording) {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading the saved transcript…")
            }
        } else if recording.transcriptionStatus == .transcribing ||
                    recording.transcriptionStatus == .notStarted {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("The transcript will appear here when processing finishes.")
            }
        } else if recording.transcriptionStatus == .complete,
                  model.transcriptDocument(for: recording) != nil {
            ContentUnavailableView(
                "No speech detected",
                systemImage: "waveform.slash",
                description: Text("Transcription finished, but no speech was detected in this recording.")
            )
        } else if recording.transcriptionStatus == .waitingForCredential {
            ContentUnavailableView {
                Label("Deepgram key needed", systemImage: "key.fill")
            } description: {
                Text("Add a key in Settings to transcribe this recording.")
            } actions: {
                SettingsLink {
                    Text("Add Key in Settings…")
                }
            }
        } else {
            ContentUnavailableView(
                "Transcript unavailable",
                systemImage: "text.page.slash",
                description: Text("Use the actions below to reveal or retry the transcript.")
            )
        }
    }

    private var infoContent: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                infoRow("Recorded", recordedDate(recording.effectiveStartedAt, detail: true))
                if let endedAt = recording.effectiveEndedAt {
                    infoRow("Ended", recordedDate(endedAt, detail: true))
                }
                if let duration = recording.durationSeconds {
                    infoRow("Duration", formattedRecordingDuration(duration))
                }
                infoRow("Audio", recording.audioStatusText(hasRecoveryAudio: model.recoveryBytes(for: recording) > 0))
                infoRow("Transcript", recording.transcriptStatusText)
                infoRow(
                    "Source",
                    recording.effectiveOrigin == .importedAudio ? "Imported audio" : "Call Recorder"
                )
                infoRow("Language", recording.language.displayName)
                infoRow("Microphone", recording.microphoneName)
                if let timeZoneIdentifier = recording.timeZoneIdentifier {
                    infoRow("Time zone", timeZoneIdentifier)
                }
                infoRow("Association", meetingAssociationDescription)
                if let calendarTitle = recording.calendarTitle {
                    infoRow("Calendar event", calendarTitle)
                }
                if let calendarStartDate = recording.calendarStartDate,
                   let calendarEndDate = recording.calendarEndDate {
                    infoRow("Meeting time", meetingInterval(calendarStartDate, calendarEndDate))
                }
                if let attendees = recording.calendarAttendeeNames, !attendees.isEmpty {
                    infoRow("Attendees", attendees.joined(separator: ", "))
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)

            if let captureHealthSummary = recording.captureHealthSummary {
                detailNotice(
                    captureHealthSummary,
                    systemImage: "exclamationmark.triangle.fill",
                    color: .orange
                )
            }
            if let failure = recording.lastFailure {
                detailNotice(
                    failure.message,
                    systemImage: "exclamationmark.circle.fill",
                    color: .red
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            primaryFooterAction

            if model.transcriptDocument(for: recording) != nil {
                Button {
                    model.exportTranscript(in: recording)
                } label: {
                    responsiveActionLabel(
                        title: "Export Transcript…",
                        compactTitle: "Export…",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .help("Save a Markdown copy with the current speaker labels")
            }

            Spacer()

            Menu {
                if recording.files.transcriptMarkdown != nil {
                    Button {
                        model.copyTranscript(in: recording)
                    } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }

                    Button {
                        model.revealTranscript(in: recording)
                    } label: {
                        Label("Reveal Transcript", systemImage: "doc.text")
                    }
                }

                if recording.files.audio != nil {
                    Button {
                        model.revealAudio(in: recording)
                    } label: {
                        Label("Reveal Audio", systemImage: "folder")
                    }
                }

                if recording.files.transcriptMarkdown == nil,
                   recording.files.audio == nil {
                    Text("No file actions available")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
            .disabled(recording.files.transcriptMarkdown == nil && recording.files.audio == nil)

            Divider()
                .frame(height: 18)

            Button(role: .destructive) {
                reading.suspendFollowing()
                deleteAction()
            } label: {
                Label(deletionActionTitle, systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .disabled(!model.canDelete(recording))
            .help(deletionActionTitle)
            .accessibilityLabel(deletionActionTitle)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var primaryFooterAction: some View {
        if model.shouldOfferFinalizationRecovery(for: recording) {
            Button {
                model.recoverFinalization(for: recording)
            } label: {
                responsiveActionLabel(
                    title: "Retry Saving Audio",
                    compactTitle: "Retry",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(!model.canRecoverFinalization(for: recording))
            .help("Retry saving audio")
        } else if model.shouldOfferTranscriptionRetry(for: recording) {
            let title = model.transcriptionRetryIsLocal(for: recording)
                ? "Recreate Transcript"
                : "Upload Again…"
            Button {
                if model.transcriptionRetryIsLocal(for: recording) {
                    model.retryTranscription(for: recording)
                } else {
                    reuploadAction()
                }
            } label: {
                responsiveActionLabel(
                    title: title,
                    compactTitle: "Retry",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(!model.canRetryTranscription(for: recording))
            .help(title)
        } else if recording.files.transcriptMarkdown != nil {
            Button {
                model.copyTranscript(in: recording)
            } label: {
                responsiveActionLabel(
                    title: "Copy Transcript",
                    compactTitle: "Copy",
                    systemImage: "doc.on.doc"
                )
            }
            .help("Copy with current speaker labels. Edits made in Finder are not included.")
        }
    }

    private func responsiveActionLabel(
        title: String,
        compactTitle: String,
        systemImage: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: systemImage)
            Label(compactTitle, systemImage: systemImage)
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
    }

    private var deletionActionTitle: String {
        recording.effectiveOrigin == .importedAudio
            ? "Remove from History…"
            : "Delete Recording…"
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchMatchSummary: String {
        let count = searchMatches.count
        guard count > 0 else { return "No transcript matches" }
        let current = min(selectedSearchMatchIndex, count - 1) + 1
        return count == 1 ? "1 of 1 match" : "\(current) of \(count) matches"
    }

    private var searchMatchAccessibilityLabel: String {
        let count = searchMatches.count
        guard count > 0 else { return "No transcript matches" }
        let current = min(selectedSearchMatchIndex, count - 1) + 1
        return "Match \(current) of \(count)"
    }

    private var activeSearchMatch: TranscriptSearchMatch? {
        guard searchMatches.indices.contains(selectedSearchMatchIndex) else { return nil }
        return searchMatches[selectedSearchMatchIndex]
    }

    private var hasTitleChanges: Bool {
        RecordingManifest.normalizedTitle(titleDraft) !=
            RecordingManifest.normalizedTitle(recording.displayTitle)
    }

    private func beginTitleEditing() {
        reading.suspendFollowing()
        titleDraft = recording.displayTitle
        titleSaveErrorMessage = nil
        isEditingTitle = true
        titleIsFocused = true
    }

    private func resetTitleEditor() {
        titleDraft = recording.displayTitle
        titleSaveErrorMessage = nil
        isEditingTitle = false
        titleIsFocused = false
    }

    private func saveTitle() {
        guard hasTitleChanges else {
            isEditingTitle = false
            titleIsFocused = false
            return
        }
        guard model.canEditMetadata(for: recording) else {
            titleSaveErrorMessage = "Wait for this recording to finish processing, then try again."
            return
        }

        do {
            try model.renameRecording(recording, to: titleDraft)
            titleSaveErrorMessage = nil
            isEditingTitle = false
            titleIsFocused = false
        } catch {
            titleSaveErrorMessage = error.localizedDescription
            titleIsFocused = true
        }
    }

    private func beginRename(_ segment: TranscriptSegment) {
        reading.suspendFollowing()
        let target = SpeakerRenameTarget(channel: segment.channel, speaker: segment.speaker)
        speakerNameDraft = recording.speakerDisplayName(
            channel: segment.channel,
            speaker: segment.speaker
        )
        renameTarget = target
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func detailNotice(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
    }

    private func meetingInterval(_ start: Date, _ end: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = recordedTimeZone
        return formatter.string(from: start, to: end)
    }

    private func recordedDate(_ date: Date, detail: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = detail ? .long : .medium
        formatter.timeStyle = detail ? .medium : .short
        formatter.timeZone = recordedTimeZone
        return formatter.string(from: date)
    }

    private var recordedTimeZone: TimeZone {
        recording.timeZoneIdentifier.flatMap { TimeZone(identifier: $0) } ?? .current
    }

    private var meetingAssociationDescription: String {
        switch recording.effectiveMeetingAssociationState {
        case .automatic: "Selected automatically"
        case .manual: "Chosen by you"
        case .unresolved: "Needs a choice"
        case .none: "No calendar meeting"
        }
    }
}

private struct SpeakerRenameTarget {
    var channel: Int
    var speaker: Int?
}
