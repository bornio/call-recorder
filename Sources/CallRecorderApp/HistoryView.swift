import CallRecorderCore
import Foundation
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedRecordingID: UUID?
    @State private var searchText = ""
    @State private var evaluatedSearchText = ""
    @State private var matchingRecordingIDs: Set<UUID> = []
    @State private var selectedTranscriptMatches: [TranscriptSearchMatch] = []
    @State private var searchUpdateTask: Task<Void, Never>?
    @State private var isUpdatingSearchResults = false
    @State private var selectedSearchMatchIndex = 0
    @State private var selectedDetailSection = RecordingDetailSection.transcript
    @State private var pendingDeletion: RecordingManifest?
    @State private var pendingReupload: RecordingManifest?
    @State private var isDropTargeted = false

    var body: some View {
        historyContent
            .alert(
                "Unable to complete action",
                isPresented: historyErrorIsPresented
            ) {
                Button("OK") { model.historyErrorMessage = nil }
            } message: {
                Text(model.historyErrorMessage ?? "Unknown error")
            }
            .alert(
                deletionAlertTitle,
                isPresented: deletionIsPresented,
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
                isPresented: reuploadIsPresented,
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

    private var historyContent: some View {
        historyUpdateContent
            .onChange(of: searchText) { _, newValue in
                selectedSearchMatchIndex = 0
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedDetailSection = .transcript
                }
                scheduleSearchUpdate(debounced: true)
            }
            .onChange(of: selectedRecordingID) { _, _ in
                selectedSearchMatchIndex = 0
                scheduleSearchUpdate(debounced: false)
            }
            .onChange(of: selectedTranscriptMatches.count) { _, count in
                selectedSearchMatchIndex = count == 0
                    ? 0
                    : min(selectedSearchMatchIndex, count - 1)
            }
    }

    private var historyUpdateContent: some View {
        historyLifecycleContent
            .onReceive(model.$recordings) { _ in
                scheduleSearchUpdate(debounced: false)
            }
            .onReceive(model.$transcriptDocuments) { _ in
                scheduleSearchUpdate(debounced: false)
            }
            .onChange(of: filteredRecordingIDs, initial: true) { _, ids in
                if let selectedRecordingID, ids.contains(selectedRecordingID) { return }
                self.selectedRecordingID = ids.first
            }
    }

    private var historyLifecycleContent: some View {
        searchableContent
            .dropDestination(for: URL.self) { urls, _ in
                model.transcribeDroppedAudio(urls)
            } isTargeted: { targeted in
                isDropTargeted = targeted && model.canImportAudio
            }
            .onAppear {
                model.setHistoryPresented(true)
                model.refreshHistoryFromFinder()
                scheduleSearchUpdate(debounced: false)
            }
            .onDisappear {
                searchUpdateTask?.cancel()
                model.setHistoryPresented(false)
            }
    }

    private var searchableContent: some View {
        ZStack {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
            } detail: {
                detail
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
        .searchable(text: $searchText, prompt: "Search recordings")
        .onSubmit(of: .search) {
            if isUpdatingSearchResults {
                scheduleSearchUpdate(debounced: false)
            } else {
                showNextSearchMatch()
            }
        }
        .focusedSceneValue(
            \.recordingSearchNavigation,
            transcriptSearchNavigation
        )
        .toolbar { historyToolbar }
    }

    @ViewBuilder
    private var sidebar: some View {
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
                }
            }
        } else if filteredRecordings.isEmpty {
            searchEmptyState
        } else {
            List(filteredRecordings, selection: $selectedRecordingID) { recording in
                RecordingSidebarRow(
                    recording: recording,
                    recoveryBytes: model.recoveryBytes(for: recording)
                )
                .tag(recording.id)
                .contextMenu {
                    if recording.files.audio != nil {
                        Button("Reveal Audio") { model.revealAudio(in: recording) }
                    }
                    if recording.files.transcriptMarkdown != nil {
                        Button("Reveal Transcript") { model.revealTranscript(in: recording) }
                        Button("Copy Transcript") { model.copyTranscript(in: recording) }
                    }
                    if model.canDelete(recording) {
                        Divider()
                        Button(deletionMenuTitle(for: recording), role: .destructive) {
                            pendingDeletion = recording
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let recording = selectedRecording {
            RecordingDetailView(
                recording: recording,
                searchText: evaluatedSearchText,
                searchMatches: selectedTranscriptMatches,
                selectedSearchMatchIndex: $selectedSearchMatchIndex,
                selectedSection: $selectedDetailSection,
                deleteAction: { pendingDeletion = recording },
                reuploadAction: { pendingReupload = recording }
            )
            .environmentObject(model)
        } else if filteredRecordings.isEmpty, !searchText.isEmpty {
            searchEmptyState
        } else {
            ContentUnavailableView(
                "Select a recording",
                systemImage: "waveform",
                description: Text("Choose a recording to play audio or read its transcript.")
            )
        }
    }

    @ToolbarContentBuilder
    private var historyToolbar: some ToolbarContent {
        ToolbarItemGroup {
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
        }
    }

    @ViewBuilder
    private var searchEmptyState: some View {
        if isUpdatingSearchResults || model.isRefreshingHistory {
            ContentUnavailableView {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching Recordings…")
                }
            } description: {
                Text("Checking recording details and transcript text.")
            }
        } else if hasUnindexedTranscripts {
            ContentUnavailableView(
                "Some transcripts aren't searchable yet",
                systemImage: "text.magnifyingglass",
                description: Text("Completed transcripts are still loading or unavailable. Results update automatically when they become searchable.")
            )
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var filteredRecordings: [RecordingManifest] {
        guard !normalizedSearchText.isEmpty else { return model.recordings }
        return model.recordings.filter { matchingRecordingIDs.contains($0.id) }
    }

    private var filteredRecordingIDs: [UUID] {
        filteredRecordings.map(\.id)
    }

    private var selectedRecording: RecordingManifest? {
        guard let selectedRecordingID else { return nil }
        return filteredRecordings.first { $0.id == selectedRecordingID }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasUnindexedTranscripts: Bool {
        model.recordings.contains {
            $0.transcriptionStatus == .complete && model.transcriptDocument(for: $0) == nil
        }
    }

    private var transcriptSearchNavigation: RecordingSearchNavigation? {
        guard !normalizedSearchText.isEmpty,
              normalizedSearchText == evaluatedSearchText,
              selectedDetailSection == .transcript,
              selectedRecording != nil,
              !isUpdatingSearchResults
        else { return nil }

        return RecordingSearchNavigation(
            canNavigate: !selectedTranscriptMatches.isEmpty,
            previous: showPreviousSearchMatch,
            next: showNextSearchMatch
        )
    }

    private func scheduleSearchUpdate(debounced: Bool) {
        searchUpdateTask?.cancel()
        let query = normalizedSearchText

        guard !query.isEmpty else {
            evaluatedSearchText = ""
            matchingRecordingIDs = Set(model.recordings.map(\.id))
            selectedTranscriptMatches = []
            isUpdatingSearchResults = false
            return
        }

        isUpdatingSearchResults = true
        searchUpdateTask = Task { @MainActor in
            if debounced {
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled, query == normalizedSearchText else { return }

            let snapshots = model.recordings.map { recording in
                RecordingSearchSnapshot(
                    recording: recording,
                    recoveryBytes: model.recoveryBytes(for: recording),
                    document: model.transcriptDocument(for: recording)
                )
            }
            let selectedRecordingID = self.selectedRecordingID
            let worker = Task.detached(priority: .userInitiated) {
                () -> (Set<UUID>, [TranscriptSearchMatch])? in
                var matchingIDs: Set<UUID> = []
                for snapshot in snapshots {
                    guard !Task.isCancelled else { return nil }
                    if recordingMatchesSearch(snapshot, query: query) {
                        matchingIDs.insert(snapshot.recording.id)
                    }
                }
                guard !Task.isCancelled else { return nil }
                let matches = snapshots.first { $0.recording.id == selectedRecordingID }
                    .map { transcriptMatches(in: $0, query: query) } ?? []
                guard !Task.isCancelled else { return nil }
                return (matchingIDs, matches)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard let result,
                  !Task.isCancelled,
                  query == normalizedSearchText
            else { return }
            matchingRecordingIDs = result.0
            evaluatedSearchText = query
            selectedTranscriptMatches = result.1
            isUpdatingSearchResults = false
        }
    }

    private func showNextSearchMatch() {
        let count = selectedTranscriptMatches.count
        guard count > 0 else { return }
        selectedDetailSection = .transcript
        selectedSearchMatchIndex = (selectedSearchMatchIndex + 1) % count
        announceSearchMatch()
    }

    private func showPreviousSearchMatch() {
        let count = selectedTranscriptMatches.count
        guard count > 0 else { return }
        selectedDetailSection = .transcript
        selectedSearchMatchIndex = (selectedSearchMatchIndex - 1 + count) % count
        announceSearchMatch()
    }

    private func announceSearchMatch() {
        announceRecordingSearchMatch(
            index: selectedSearchMatchIndex,
            count: selectedTranscriptMatches.count
        )
    }

    private var deletionAlertTitle: String {
        guard let pendingDeletion else { return "Delete recording?" }
        return pendingDeletion.effectiveOrigin == .importedAudio
            ? "Remove from history?"
            : "Delete recording?"
    }

    private var historyErrorIsPresented: Binding<Bool> {
        Binding(
            get: { model.historyErrorMessage != nil },
            set: { if !$0 { model.historyErrorMessage = nil } }
        )
    }

    private var deletionIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var reuploadIsPresented: Binding<Bool> {
        Binding(
            get: { pendingReupload != nil },
            set: { if !$0 { pendingReupload = nil } }
        )
    }

    private func deletionActionTitle(for recording: RecordingManifest) -> String {
        recording.effectiveOrigin == .importedAudio
            ? "Remove from History"
            : "Delete Recording"
    }

    private func deletionMenuTitle(for recording: RecordingManifest) -> String {
        recording.effectiveOrigin == .importedAudio
            ? "Remove from History…"
            : "Delete Recording…"
    }
}

private struct RecordingSearchSnapshot: Sendable {
    let recording: RecordingManifest
    let recoveryBytes: Int64
    let document: TranscriptDocument?
}

private func recordingMatchesSearch(
    _ snapshot: RecordingSearchSnapshot,
    query: String
) -> Bool {
    let recording = snapshot.recording
    let metadata = [
        recording.displayTitle,
        recording.importedSourceFilename ?? "",
        recording.language.displayName,
        recording.microphoneName,
        recording.audioStatusText(hasRecoveryAudio: snapshot.recoveryBytes > 0),
        recording.transcriptStatusText,
        recording.calendarTitle ?? "",
        recording.calendarAttendeeNames?.joined(separator: " ") ?? "",
    ]
    if metadata.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
        return true
    }
    return snapshot.document?.segments.contains {
        $0.text.localizedCaseInsensitiveContains(query) ||
            recording.speakerDisplayName(channel: $0.channel, speaker: $0.speaker)
                .localizedCaseInsensitiveContains(query)
    } == true
}

private func transcriptMatches(
    in snapshot: RecordingSearchSnapshot,
    query: String
) -> [TranscriptSearchMatch] {
    guard let document = snapshot.document else { return [] }
    let recording = snapshot.recording
    return TranscriptSearchMatch.find(
        in: document,
        query: query,
        speakerName: {
            recording.speakerDisplayName(channel: $0.channel, speaker: $0.speaker)
        }
    )
}

private struct RecordingSidebarRow: View {
    let recording: RecordingManifest
    let recoveryBytes: Int64

    var body: some View {
        HStack(spacing: 10) {
            RecordingStatusSymbol(recording: recording)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.displayTitle)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if recording.effectiveOrigin == .importedAudio {
                        Text("Imported")
                        Text("·")
                    }
                    Text(recordedStart)
                    if let duration = recording.durationSeconds {
                        Text("·")
                        Text(formattedRecordingDuration(duration))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                HStack(spacing: 5) {
                    Text("Audio \(recording.audioStatusText(hasRecoveryAudio: recoveryBytes > 0))")
                    Text("·")
                    Text("Transcript \(recording.transcriptStatusText)")
                    if recording.effectiveMeetingAssociationState == .unresolved {
                        Text("·")
                        Label("Choose meeting", systemImage: "calendar.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .help(helpText)
        .accessibilityElement(children: .combine)
    }

    private var helpText: String {
        var values = [
            "Audio: \(recording.audioStatusText(hasRecoveryAudio: recoveryBytes > 0))",
            "Transcript: \(recording.transcriptStatusText)",
        ]
        if let captureHealthSummary = recording.captureHealthSummary {
            values.append(captureHealthSummary)
        }
        if let failure = recording.lastFailure {
            values.append(failure.message)
        }
        if recording.effectiveMeetingAssociationState == .unresolved {
            values.append("Calendar meeting needs a choice")
        }
        return values.joined(separator: ". ")
    }

    private var recordedStart: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = recording.timeZoneIdentifier
            .flatMap { TimeZone(identifier: $0) } ?? .current
        return formatter.string(from: recording.effectiveStartedAt)
    }

}

private struct RecordingStatusSymbol: View {
    let recording: RecordingManifest

    var body: some View {
        if recording.transcriptionStatus == .waitingForCredential {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Deepgram key needed")
        } else if recording.hasFailure {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Needs attention")
        } else if recording.isProcessing {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Processing")
        } else if recording.captureHealthSummary != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Recording completed with warnings")
        } else if recording.transcriptionStatus == .complete {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Transcript ready")
        } else {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Waiting")
        }
    }
}
