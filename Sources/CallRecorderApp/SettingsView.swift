import AppKit
import CallRecorderCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newAPIKey = ""
    @State private var showingRemoveKeyConfirmation = false
    @State private var showingForgetHistoryConfirmation = false

    var body: some View {
        Form {
            if !model.canChangeCaptureConfiguration {
                Section {
                    Label(
                        "Recording, Calendar, and transcription-accuracy settings are locked until capture stops.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Recording") {
                Picker("Microphone", selection: $model.selectedMicrophoneUID) {
                    Text(model.automaticMicrophoneLabel)
                        .tag(AppModel.automaticMicrophoneUID)
                    ForEach(model.microphones) { microphone in
                        Text(microphone.name).tag(microphone.uid)
                    }
                }
                .disabled(!model.canChangeCaptureConfiguration)

                Picker("Transcription language", selection: $model.language) {
                    ForEach(RecordingLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .disabled(!model.canChangeCaptureConfiguration)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Your name in transcripts")
                    TextField("Enter your name", text: $model.localSpeakerName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Your name in transcripts")
                        .disabled(!model.canChangeCaptureConfiguration)
                        .onSubmit { model.normalizeLocalSpeakerName() }
                    Text("Type the name that should label your microphone channel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Save recordings to") {
                    HStack {
                        Text(model.outputDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.outputDirectory.path)
                        Button("Choose…") { model.chooseOutputDirectory() }
                            .disabled(!model.canChangeCaptureConfiguration)
                    }
                }
                Text("Each call is saved with Audio.m4a and Transcript.md. Recording details remain in the Markdown even if transcription fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.outputDirectoryErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Calendar") {
                Toggle(
                    "Use Calendar for meeting context",
                    isOn: Binding(
                        get: { model.calendarSuggestionsEnabled },
                        set: { model.setCalendarSuggestionsEnabled($0) }
                    )
                )
                .disabled(!model.canChangeCaptureConfiguration)

                if model.calendarSuggestionsEnabled {
                    calendarAccessContent
                        .disabled(!model.canChangeCaptureConfiguration)
                }

                Text("Calendar data stays on this Mac. Call Recorder reads selected calendars to suggest a meeting title and may retain the matched meeting time and attendee names in private app history. It never starts a recording or changes an event.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription accuracy") {
                Toggle(
                    "Improve names and jargon (paid Deepgram add-on)",
                    isOn: $model.keytermPromptingEnabled
                )
                .disabled(!model.canChangeCaptureConfiguration)

                if model.keytermPromptingEnabled {
                    Text("Enter one name, company, product, acronym, or phrase per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "Key terms",
                        text: $model.keytermsText,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .disabled(!model.canChangeCaptureConfiguration)

                    if model.keytermsAreLimited {
                        Label(
                            "Only the first \(DeepgramKeyterms.maximumCount) terms will be used.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    } else if model.keytermCount == 0 {
                        Text("Add at least one term to enable prompting.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(model.keytermCount) of \(DeepgramKeyterms.maximumCount) terms")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Terms are sent to Deepgram and billed separately only when this option is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Deepgram") {
                HStack {
                    Image(systemName: model.hasDeepgramKey ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.hasDeepgramKey ? .green : .secondary)
                    Text(
                        credentialStatusText
                    )
                }
                if model.canPersistDeepgramKey {
                    SecureField("New Deepgram API key", text: $newAPIKey)
                        .textContentType(.password)
                    HStack {
                        Button("Save Key") {
                            if model.saveDeepgramKey(newAPIKey) {
                                newAPIKey = ""
                            }
                        }
                        .disabled(newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Remove Keychain Key", role: .destructive) {
                            showingRemoveKeyConfirmation = true
                        }
                        .disabled(!model.hasStoredDeepgramKey)
                    }
                } else {
                    Label("Keychain disabled for this development build", systemImage: "hammer")
                        .foregroundStyle(.secondary)
                }
                Text(credentialDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.keychainErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Storage") {
                LabeledContent("Private app history") {
                    Text(formattedBytes(model.storageUsage.privateHistoryBytes))
                        .monospacedDigit()
                }
                LabeledContent("Audio recovery data") {
                    Text(formattedBytes(model.storageUsage.recoveryBytes))
                        .monospacedDigit()
                }
                Text("Private history includes saved Deepgram responses used to recreate transcripts without another paid upload. Recovery data is temporary audio retained after an interruption or failed save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("Open App Data Folder") { model.openAppDataFolder() }
                        refreshStorageButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Open App Data Folder") { model.openAppDataFolder() }
                        refreshStorageButton
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Button(role: .destructive) {
                        showingForgetHistoryConfirmation = true
                    } label: {
                        if model.isForgettingHistory {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Forgetting History…")
                            }
                        } else {
                            Text("Forget History, Keep Finder Files…")
                        }
                    }
                    .disabled(!model.canForgetHistory)
                    if let reason = model.forgetHistoryUnavailableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.storageErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Permissions") {
                Text("macOS asks for Microphone and System Audio Recording access the first time recording starts.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Microphone Settings") { model.openMicrophonePrivacySettings() }
                    Button("System Audio Settings") { model.openSystemAudioPrivacySettings() }
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            model.refreshMicrophonesAsync()
            model.refreshCredentialStatus()
            model.refreshStorageUsage()
            model.refreshCalendarContextIfStale()
        }
        .onDisappear {
            newAPIKey = ""
            model.normalizeLocalSpeakerName()
            model.normalizeKeyterms()
        }
        .confirmationDialog(
            "Remove the saved Deepgram key?",
            isPresented: $showingRemoveKeyConfirmation
        ) {
            Button("Remove Keychain Key", role: .destructive) {
                model.removeDeepgramKey()
                newAPIKey = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeKeyConfirmationMessage)
        }
        .confirmationDialog(
            "Forget all app history?",
            isPresented: $showingForgetHistoryConfirmation
        ) {
            Button("Forget History", role: .destructive) {
                model.forgetHistoryKeepingExports()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes private manifests, saved Deepgram responses, and recovery audio. Every Finder file remains, including app exports and imported source audio. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var calendarAccessContent: some View {
        switch model.calendarAccessState {
        case .fullAccess:
            Label("Calendar access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            if model.availableCalendars.isEmpty {
                Text("No event calendars are available.")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup {
                    ForEach(model.availableCalendars) { calendar in
                        Toggle(
                            isOn: Binding(
                                get: { model.calendarIsSelected(calendar) },
                                set: { model.setCalendar(calendar, selected: $0) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(calendar.title)
                                Text(calendar.sourceTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Calendars")
                        Spacer()
                        Text("\(selectedCalendarCount) of \(model.availableCalendars.count) selected")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Button("Refresh Calendar") {
                model.refreshCalendarContext()
            }
            .disabled(model.isRefreshingCalendar)
        case .notDetermined:
            Button("Allow Calendar Access…") {
                model.refreshCalendarContext(requestAccess: true)
            }
            .disabled(model.isRefreshingCalendar)
        case .denied, .restricted, .writeOnly:
            Label(
                "Call Recorder cannot read calendar events.",
                systemImage: "calendar.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
            Button("Calendar Privacy Settings") {
                model.openCalendarPrivacySettings()
            }
        case .unavailable:
            Label("Calendar access is unavailable.", systemImage: "calendar.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }

        if model.isRefreshingCalendar {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Calendar…")
                    .foregroundStyle(.secondary)
            }
        }

        if let error = model.calendarErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var refreshStorageButton: some View {
        HStack(spacing: 8) {
            Button("Refresh") { model.refreshStorageUsage() }
                .disabled(model.isRefreshingStorage)
            if model.isRefreshingStorage {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing storage usage")
            }
        }
    }

    private var selectedCalendarCount: Int {
        model.availableCalendars.lazy.filter(model.calendarIsSelected).count
    }

    private var credentialStatusText: String {
        if !model.canPersistDeepgramKey {
            return model.deepgramCredentialSource == .environment
                ? "Deepgram key ready from development environment"
                : "Development mode"
        }
        return switch model.deepgramCredentialSource {
        case .environment: "Deepgram key ready from environment"
        case .keychain: "Deepgram key ready from Keychain"
        case .none: "Add a Deepgram API key to transcribe recordings"
        }
    }

    private var credentialDetailText: String {
        if !model.canPersistDeepgramKey {
            return model.deepgramCredentialSource == .environment
                ? "This development build uses DEEPGRAM_API_KEY for this process and never reads or writes Keychain."
                : "This development build never reads or writes Keychain. Set DEEPGRAM_API_KEY before launch only when live transcription testing is needed."
        }
        return switch model.deepgramCredentialSource {
        case .environment:
            "DEEPGRAM_API_KEY currently takes precedence. A key saved here is stored in Keychain and never written to recording files."
        case .keychain:
            "The key is stored securely in Keychain and is never written to recording files."
        case .none:
            "Keys saved here are stored securely in Keychain and never written to recording files."
        }
    }

    private var removeKeyConfirmationMessage: String {
        if model.deepgramCredentialSource == .environment {
            return "This removes only the saved Keychain key. DEEPGRAM_API_KEY remains active and is not changed."
        }
        return "Future recordings will need another key before they can be transcribed."
    }
}

private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
