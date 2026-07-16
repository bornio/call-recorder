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
            Section("Recording") {
                if !model.canChangeCaptureConfiguration {
                    Label(
                        "Stop recording to change these settings.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

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
                        Button("Choose…") { model.chooseOutputDirectory() }
                            .disabled(!model.canChangeCaptureConfiguration)
                    }
                }
                Text("Each call is saved in its own folder with Audio.m4a and, when transcription succeeds, Transcript.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.outputDirectoryErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Transcription accuracy") {
                Toggle(
                    "Improve names and jargon (paid Deepgram add-on)",
                    isOn: $model.keytermPromptingEnabled
                )

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
                HStack {
                    Button("Open App Data Folder") { model.openAppDataFolder() }
                    Button("Refresh") { model.refreshStorageUsage() }
                        .disabled(model.isRefreshingStorage)
                    if model.isRefreshingStorage {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing storage usage")
                    }
                    Spacer()
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
                }
                if let reason = model.forgetHistoryUnavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            model.refreshMicrophones()
            model.refreshCredentialStatus()
            model.refreshStorageUsage()
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

    private var credentialStatusText: String {
        switch model.deepgramCredentialSource {
        case .environment: "Deepgram key ready from environment"
        case .keychain: "Deepgram key ready from Keychain"
        case .none: "Add a Deepgram API key to transcribe recordings"
        }
    }

    private var credentialDetailText: String {
        switch model.deepgramCredentialSource {
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
