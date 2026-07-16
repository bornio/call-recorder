import AppKit
import CallRecorderCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newAPIKey = ""

    var body: some View {
        Form {
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
                    Text("Your transcript name")
                    TextField("Enter your name", text: $model.localSpeakerName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Your transcript name")
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
                Text("Each finished call becomes one clean folder with Audio.m4a and, when transcription succeeds, Transcript.md. Temporary recovery files stay private and are removed after the compressed audio is validated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text(model.hasDeepgramKey ? "Deepgram credential available" : "No Deepgram credential available")
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
                    Button("Remove Key", role: .destructive) {
                        model.removeDeepgramKey()
                        newAPIKey = ""
                    }
                    .disabled(!model.hasDeepgramKey)
                }
                Text("The key is never displayed or written to recording files. DEEPGRAM_API_KEY may be used as a development-only override.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                Text("macOS asks for Microphone and System Audio Recording access the first time recording starts.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Microphone Settings") { model.openMicrophonePrivacySettings() }
                    Button("System Audio Settings") { model.openSystemAudioPrivacySettings() }
                }
            }

            if let error = model.settingsErrorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            model.refreshMicrophones()
            model.refreshCredentialStatus()
        }
        .onDisappear {
            newAPIKey = ""
            model.normalizeLocalSpeakerName()
            model.normalizeKeyterms()
        }
    }
}
