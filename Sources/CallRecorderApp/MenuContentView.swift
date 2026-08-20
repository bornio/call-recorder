import AppKit
import CallRecorderCore
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MenuHeader(model: model, aboutAction: showAbout)

            Divider()

            AdaptiveMenuScrollView(maximumHeight: 360) {
                VStack(alignment: .leading, spacing: 14) {
                    if model.isPreparingToTerminate {
                        TerminationContent(model: model)
                    } else {
                        captureContent
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            VStack(spacing: 8) {
                Button(action: showRecordings) {
                    Label("Recordings", systemImage: "tray.full")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let applicationVersion {
                    Text("Version \(applicationVersion)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Call Recorder version \(applicationVersion)")
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            model.setMenuPresented(true)
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            model.refreshMicrophonesAsync()
            model.refreshCalendarContextIfStale()
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

    private func showAbout() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    private var applicationVersion: String? {
        guard let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
              !version.isEmpty
        else { return nil }
        return version
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

private struct MenuHeader: View {
    @ObservedObject var model: AppModel
    let aboutAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Call Recorder")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                SettingsLink { Text("Settings…") }
                Button("About Call Recorder", action: aboutAction)
                Divider()
                Button("Quit Call Recorder") {
                    NSApplication.shared.terminate(nil)
                }
                .disabled(model.isPreparingToTerminate)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Call Recorder menu")
        }
    }

    private var statusText: String {
        if model.isPreparingToTerminate { return "Finishing before quit" }
        return switch model.captureState {
        case .ready: "Ready to record"
        case .starting: "Starting recording"
        case .recording: "Recording"
        case .paused: "Recording paused"
        case .stopping: model.isCancelling ? "Discarding recording" : "Saving recording"
        }
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
                Button("Dismiss") {
                    model.dismissCaptureIssue()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

private struct ReadyCaptureContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.calendarSuggestionsEnabled {
                CalendarContextView(model: model)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Recording title")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "Optional title",
                    text: Binding(
                        get: { model.recordingTitle },
                        set: { model.setRecordingTitle($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Recording title")
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
                .pickerStyle(.segmented)
                .frame(width: 220)
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
            .disabled(!model.canStartRecording)

            Text("Click Start to begin recording.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private struct CalendarContextView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if !model.calendarCandidates.isEmpty || model.calendarChoiceWasMade {
                VStack(alignment: .leading, spacing: 4) {
                    Label(contextLabel, systemImage: contextSystemImage)
                        .font(.caption)
                        .foregroundStyle(model.calendarSelectionNeedsReview ? .orange : .secondary)

                    Menu {
                        ForEach(model.calendarCandidates) { event in
                            Button(meetingChoiceTitle(event)) {
                                model.selectCalendarSuggestion(event)
                            }
                        }
                        Divider()
                        Button("No calendar meeting") {
                            model.selectCalendarSuggestion(nil)
                        }
                    } label: {
                        HStack {
                            Text(selectionTitle)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Meeting")
                    .accessibilityValue(selectionTitle)

                    if let suggestion = model.calendarSuggestion {
                        Text(meetingTime(for: suggestion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !suggestion.attendeeNames.isEmpty {
                            Text(suggestion.attendeeNames.prefix(4).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if model.calendarSelectionNeedsReview {
                        Text("The app can decide after Stop, or you can choose now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Meeting title and time stay in Transcript.md. Attendee names remain only in private app history.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else if model.isRefreshingCalendar {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking Calendar…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.calendarAccessState == .fullAccess {
                Label("No meeting near this recording", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Group {
                    switch model.calendarAccessState {
                    case .notDetermined:
                        Button {
                            model.refreshCalendarContext(requestAccess: true)
                        } label: {
                            Label("Connect Calendar…", systemImage: "calendar.badge.plus")
                        }
                    case .denied, .restricted, .writeOnly:
                        Button {
                            model.openCalendarPrivacySettings()
                        } label: {
                            Label(
                                "Calendar Privacy Settings…",
                                systemImage: "calendar.badge.exclamationmark"
                            )
                        }
                    case .unavailable:
                        Label(
                            "Calendar access is unavailable",
                            systemImage: "calendar.badge.exclamationmark"
                        )
                        .foregroundStyle(.secondary)
                    case .fullAccess:
                        EmptyView()
                    }
                }
                .font(.caption)
            }
        }
    }

    private var selectionTitle: String {
        if let suggestion = model.calendarSuggestion { return suggestion.title }
        if model.calendarSelectionNeedsReview { return "Choose meeting…" }
        return "No calendar meeting"
    }

    private var contextLabel: String {
        if model.calendarSelectionNeedsReview { return "Meeting needs a choice" }
        if model.calendarChoiceWasMade, model.calendarSuggestion == nil {
            return "Calendar association"
        }
        if let suggestion = model.calendarSuggestion {
            return meetingLabel(for: suggestion)
        }
        return "Calendar association"
    }

    private var contextSystemImage: String {
        model.calendarSelectionNeedsReview
            ? "calendar.badge.exclamationmark"
            : "calendar"
    }

    private func meetingLabel(for suggestion: CalendarEventCandidate) -> String {
        let now = Date()
        if suggestion.endDate <= now { return "Previous meeting" }
        return suggestion.startDate <= now ? "Current meeting" : "Next meeting"
    }

    private func meetingTime(for suggestion: CalendarEventCandidate) -> String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: suggestion.startDate, to: suggestion.endDate)
    }

    private func shortMeetingTitle(_ title: String) -> String {
        guard title.count > 30 else { return title }
        return String(title.prefix(27)) + "..."
    }

    private func meetingChoiceTitle(_ event: CalendarEventCandidate) -> String {
        [
            shortMeetingTitle(event.title),
            meetingTime(for: event),
            event.calendarName,
        ].compactMap { $0 }.joined(separator: " · ")
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
            }
            .opacity(isPaused ? 0.4 : 1)
            .accessibilityHidden(isPaused)

            if droppedFrames > 0 {
                Label("Audio may contain gaps", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("\(droppedFrames) audio frames were dropped during this recording.")
                    .accessibilityValue("\(droppedFrames) audio frames dropped")
            }

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

    private var droppedFrames: UInt64 {
        model.captureStatistics.summary.totalDroppedFrames
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
