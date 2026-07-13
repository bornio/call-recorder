@preconcurrency import AVFoundation
import AppKit
import CallRecorderCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct StopOutcome: Sendable {
    var statistics: CaptureLiveStatistics
    var errorMessage: String?
}

private struct FinalizeOutcome: Sendable {
    var publication: PublishedRecordingAudio?
    var warnings: [String]
    var errorMessage: String?
}

private struct CancelOutcome: Sendable {
    var statistics: CaptureLiveStatistics
    var deletionErrorMessage: String?
}

@MainActor
final class AppModel: ObservableObject {
    static weak var shared: AppModel?
    static let automaticMicrophoneUID = "__automatic_microphone__"

    @Published private(set) var phase: RecorderPhase = .idle
    @Published private(set) var recordings: [RecordingManifest] = []
    @Published private(set) var microphones: [AudioInputDevice] = []
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var captureStatistics: CaptureLiveStatistics = .empty
    @Published private(set) var hasDeepgramKey = false
    @Published private(set) var isStarting = false
    @Published private(set) var isCancelling = false
    @Published private(set) var noticeMessage: String?
    @Published var errorMessage: String?

    @Published var selectedMicrophoneUID: String {
        didSet { defaults.set(selectedMicrophoneUID, forKey: Keys.microphoneUID) }
    }
    @Published var language: RecordingLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    @Published var localSpeakerName: String {
        didSet { defaults.set(localSpeakerName, forKey: Keys.localSpeakerName) }
    }
    @Published var keytermPromptingEnabled: Bool {
        didSet { defaults.set(keytermPromptingEnabled, forKey: Keys.keytermPromptingEnabled) }
    }
    @Published var keytermsText: String {
        didSet { defaults.set(keytermsText, forKey: Keys.keytermsText) }
    }
    @Published private(set) var outputDirectory: URL

    private var stateMachine = RecorderStateMachine()
    private var captureEngine: CaptureEngine?
    private var activeRecording: RecordingManifest?
    private var recordingStartedAt: Date?
    private var pausedAt: Date?
    private var accumulatedPausedSeconds: TimeInterval = 0
    private var capturePollTask: Task<Void, Never>?
    private var fatalStopRequested = false
    private var isMenuPresented = false
    private var store: RecordingStore
    private let defaults: UserDefaults
    private let keychain = KeychainStore()
    private let audioExportService = AudioExportService()
    private let postProcessor = RecordingPostProcessor()
    private let transcriptionService = TranscriptionService()

    var isBusy: Bool {
        isStarting || isCancelling || isCaptureActive ||
            phase == .processing || phase == .transcribing
    }

    var isCaptureActive: Bool {
        phase == .recording || phase == .paused
    }

    var keytermCount: Int {
        parsedKeyterms.count
    }

    var keytermsAreLimited: Bool {
        keytermCount > DeepgramKeyterms.maximumCount
    }

    var selectedMicrophone: AudioInputDevice? {
        if selectedMicrophoneUID == Self.automaticMicrophoneUID {
            return automaticMicrophone
        }
        return microphones.first { $0.uid == selectedMicrophoneUID }
    }

    var automaticMicrophone: AudioInputDevice? {
        AudioDeviceService.preferredInputDevice(from: microphones)
    }

    var automaticMicrophoneLabel: String {
        if let microphone = automaticMicrophone {
            let reason: String
            if microphone.isInUse {
                reason = "in use"
            } else if microphone.id == AudioDeviceService.defaultInputDeviceID() {
                reason = "system default"
            } else {
                reason = "available"
            }
            return "Automatic — \(microphone.name) (\(reason))"
        }
        return "Automatic"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedOutput = defaults.string(forKey: Keys.outputDirectory)
        let output = storedOutput.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? RecordingStore.defaultRootDirectory
        outputDirectory = output
        store = RecordingStore(rootDirectory: RecordingStore.defaultHistoryDirectory)
        language = RecordingLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? ""
        ) ?? .english
        localSpeakerName = RecordingManifest.normalizedLocalSpeakerName(
            defaults.string(forKey: Keys.localSpeakerName)
        )
        keytermPromptingEnabled = defaults.bool(forKey: Keys.keytermPromptingEnabled)
        keytermsText = defaults.string(forKey: Keys.keytermsText) ?? ""
        selectedMicrophoneUID = defaults.string(forKey: Keys.microphoneUID)
            ?? Self.automaticMicrophoneUID
        Self.shared = self

        refreshMicrophones()
        refreshCredentialStatus()
        reloadHistory(recoverInterrupted: true)
        Task { [weak self] in
            await self?.recoverPendingFinalizations()
        }
    }

    func refreshMicrophones() {
        microphones = AudioDeviceService.inputDevices()
        if selectedMicrophoneUID != Self.automaticMicrophoneUID,
           !microphones.contains(where: { $0.uid == selectedMicrophoneUID }) {
            selectedMicrophoneUID = Self.automaticMicrophoneUID
        }
    }

    func reloadHistory(recoverInterrupted: Bool = false) {
        do {
            if recoverInterrupted {
                try store.recoverInterruptedRecordings()
            }
            recordings = try store.reconcileExternalFiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startRecording() {
        guard !isBusy else { return }
        isStarting = true
        Task {
            await beginRecording()
            isStarting = false
        }
    }

    func stopRecording() {
        guard !isCancelling else { return }
        Task { await finishRecording(captureFailure: nil) }
    }

    func pauseRecording() {
        guard phase == .recording, !isCancelling, let captureEngine else { return }
        do {
            try captureEngine.setPaused(true)
            do {
                try stateMachine.transition(.pause)
            } catch {
                try? captureEngine.setPaused(false)
                throw error
            }
            let now = Date()
            elapsedSeconds = floor(activeElapsed(at: now))
            pausedAt = now
            captureStatistics = captureEngine.statistics()
            phase = stateMachine.phase
            errorMessage = nil
        } catch {
            errorMessage = "Unable to pause recording: \(error.localizedDescription)"
        }
    }

    func resumeRecording() {
        guard phase == .paused, !isCancelling, let captureEngine else { return }
        do {
            try captureEngine.setPaused(false)
            do {
                try stateMachine.transition(.resume)
            } catch {
                try? captureEngine.setPaused(true)
                throw error
            }
            let now = Date()
            if let pausedAt {
                accumulatedPausedSeconds += now.timeIntervalSince(pausedAt)
            }
            self.pausedAt = nil
            phase = stateMachine.phase
            errorMessage = nil
        } catch {
            errorMessage = "Unable to resume recording: \(error.localizedDescription)"
        }
    }

    func cancelRecording() {
        guard isCaptureActive, !isCancelling else { return }
        isCancelling = true
        Task { await discardActiveRecording() }
    }

    func setMenuPresented(_ presented: Bool) {
        isMenuPresented = presented
        if presented, isCaptureActive, let captureEngine {
            captureStatistics = captureEngine.statistics()
        }
    }

    func handleSystemSleep() {
        guard isCaptureActive, !fatalStopRequested, !isCancelling else { return }
        fatalStopRequested = true
        Task {
            await finishRecording(
                captureFailure: "The Mac went to sleep during recording. Audio completed before sleep was preserved."
            )
        }
    }

    func retryTranscription(for recording: RecordingManifest) {
        guard !isBusy, TranscriptionRetryPolicy.canRetry(recording) else { return }
        errorMessage = nil
        noticeMessage = nil
        stateMachine = RecorderStateMachine(phase: phase)
        do {
            try stateMachine.transition(.retryTranscription)
            phase = stateMachine.phase
        } catch {
            fail(error.localizedDescription)
            return
        }
        Task { await runTranscription(for: recording) }
    }

    private func transcribeAudio(_ url: URL) {
        guard !isBusy, url.isFileURL else { return }
        errorMessage = nil
        noticeMessage = nil
        stateMachine = RecorderStateMachine(phase: phase)
        do {
            try stateMachine.transition(.retryTranscription)
            phase = stateMachine.phase
        } catch {
            fail(error.localizedDescription)
            return
        }
        Task { await prepareAndTranscribeImportedAudio(url) }
    }

    func delete(_ recording: RecordingManifest) {
        guard activeRecording?.id != recording.id, !isBusy else { return }
        do {
            if recording.effectiveOrigin == .nativeRecording {
                let audioURL = try store.audioURL(for: recording)
                let transcriptURL = try store.transcriptURL(for: recording)
                for url in [audioURL, transcriptURL].compactMap({ $0 })
                where FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                if let exportedDirectory = audioURL?.deletingLastPathComponent()
                    ?? transcriptURL?.deletingLastPathComponent(),
                   (try? FileManager.default.contentsOfDirectory(atPath: exportedDirectory.path))?.isEmpty == true {
                    try FileManager.default.removeItem(at: exportedDirectory)
                }
            }
            try store.delete(recording)
            reloadHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealAudio(in recording: RecordingManifest) {
        do {
            guard let url = try store.audioURL(for: recording) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealTranscript(in recording: RecordingManifest) {
        do {
            guard let url = try store.transcriptURL(for: recording) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseOutputDirectory() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose recording folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard try outputDirectoryIsLocal(url) else {
                errorMessage = "Choose a local, non-cloud-synced folder so recording stays local during the call."
                return
            }
        } catch {
            errorMessage = "Unable to verify the selected folder: \(error.localizedDescription)"
            return
        }
        outputDirectory = url.standardizedFileURL
        defaults.set(outputDirectory.path, forKey: Keys.outputDirectory)
    }

    func chooseAudioForTranscription() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose audio to transcribe"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribeAudio(url)
    }

    func transcribeDroppedAudio(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: { $0.isFileURL }), !isBusy else { return false }
        transcribeAudio(url)
        return true
    }

    func saveDeepgramKey(_ key: String) -> Bool {
        do {
            try keychain.saveDeepgramAPIKey(key)
            refreshCredentialStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeDeepgramKey() {
        do {
            try keychain.deleteDeepgramAPIKey()
            refreshCredentialStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshCredentialStatus() {
        hasDeepgramKey = keychain.hasDeepgramAPIKey()
    }

    func normalizeLocalSpeakerName() {
        localSpeakerName = RecordingManifest.normalizedLocalSpeakerName(
            localSpeakerName
        )
    }

    func normalizeKeyterms() {
        keytermsText = parsedKeyterms.joined(separator: "\n")
    }

    func openMicrophonePrivacySettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    func openSystemAudioPrivacySettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    func stopImmediatelyForTermination() {
        capturePollTask?.cancel()
        capturePollTask = nil
        if isCancelling {
            if let captureEngine {
                _ = try? captureEngine.stop()
            }
            if let activeRecording {
                try? store.delete(activeRecording)
            }
            captureEngine = nil
            activeRecording = nil
            resetCaptureTiming()
            return
        }
        guard let captureEngine, var recording = activeRecording else { return }
        let statistics = (try? captureEngine.stop()) ?? captureEngine.statistics()
        recording.captureStatus = .processing
        recording.stoppedAt = Date()
        recording.captureEndedAt = recording.stoppedAt
        recording.durationSeconds = activeElapsed(at: recording.stoppedAt ?? Date())
        recording.captureSummary = statistics.summary
        recording.lastFailure = RecordingFailure(
            stage: .capture,
            message: "The app quit before post-recording finalization. Closed capture chunks will be recovered on the next launch."
        )
        recording.routeAfter = try? CaptureEngine.defaultAudioRoutes()
        try? store.save(recording)
        self.captureEngine = nil
        activeRecording = nil
        resetCaptureTiming()
    }

    private func beginRecording() async {
        guard phase == .idle || phase == .complete || phase == .failed else { return }
        errorMessage = nil
        noticeMessage = nil
        refreshMicrophones()
        guard let microphone = selectedMicrophone else {
            fail("No microphone is available.")
            return
        }
        do {
            guard try outputDirectoryIsLocal(outputDirectory) else {
                fail("Choose a local, non-cloud-synced output folder before recording.")
                return
            }
        } catch {
            fail("Unable to verify the output folder: \(error.localizedDescription)")
            return
        }
        guard await requestMicrophoneAccess() else {
            fail("Microphone access was denied. Grant it in System Settings → Privacy & Security → Microphone.")
            return
        }

        do {
            var recording = try store.createRecording(
                language: language,
                microphoneUID: microphone.uid,
                microphoneName: microphone.name,
                localSpeakerName: RecordingManifest.normalizedLocalSpeakerName(
                    localSpeakerName
                ),
                keyterms: activeKeyterms
            )
            recording.routeBefore = try CaptureEngine.defaultAudioRoutes()
            try store.save(recording)
            let systemDirectory = try store.url(
                for: recording.files.systemCaptureDirectory,
                in: recording
            )
            let microphoneDirectory = try store.url(
                for: recording.files.microphoneCaptureDirectory,
                in: recording
            )
            let engine = CaptureEngine()
            do {
                try engine.start(
                    configuration: CaptureConfiguration(
                        systemDirectory: systemDirectory,
                        microphoneDirectory: microphoneDirectory,
                        microphoneUID: microphone.uid
                    )
                )
            } catch {
                recording.captureStatus = .failed
                recording.stoppedAt = Date()
                recording.lastFailure = RecordingFailure(
                    stage: .capture,
                    message: error.localizedDescription
                )
                _ = persistOrFail(recording)
                throw error
            }

            let startedAt = Date()
            do {
                recording.captureStartedAt = startedAt
                recording.timeZoneIdentifier = TimeZone.current.identifier
                try store.save(recording)
                stateMachine = RecorderStateMachine(phase: phase)
                try stateMachine.transition(.start)
                phase = stateMachine.phase
            } catch {
                _ = try? engine.stop()
                recording.captureStatus = .failed
                recording.stoppedAt = Date()
                recording.captureEndedAt = recording.stoppedAt
                recording.lastFailure = RecordingFailure(
                    stage: .capture,
                    message: "Recording stopped because its state could not be saved: \(error.localizedDescription)"
                )
                try? store.save(recording)
                throw error
            }
            captureEngine = engine
            activeRecording = recording
            recordingStartedAt = startedAt
            pausedAt = nil
            accumulatedPausedSeconds = 0
            elapsedSeconds = 0
            captureStatistics = engine.statistics()
            fatalStopRequested = false
            startCapturePolling()
            reloadHistory()
        } catch {
            fail(error.localizedDescription)
            reloadHistory()
        }
    }

    private func discardActiveRecording() async {
        guard isCaptureActive,
              let engine = captureEngine,
              var recording = activeRecording
        else {
            isCancelling = false
            return
        }
        capturePollTask?.cancel()
        capturePollTask = nil
        fatalStopRequested = true

        recording.captureStatus = .failed
        recording.stoppedAt = Date()
        recording.captureEndedAt = recording.stoppedAt
        recording.durationSeconds = activeElapsed(at: recording.stoppedAt ?? Date())
        recording.lastFailure = RecordingFailure(
            stage: .capture,
            message: "This recording was cancelled and could not be fully removed."
        )
        try? store.save(recording)
        activeRecording = recording

        let store = self.store
        let outcome = await Task.detached { () -> CancelOutcome in
            let statistics = (try? engine.stop()) ?? engine.statistics()
            do {
                try store.delete(recording)
                return CancelOutcome(statistics: statistics, deletionErrorMessage: nil)
            } catch {
                return CancelOutcome(
                    statistics: statistics,
                    deletionErrorMessage: error.localizedDescription
                )
            }
        }.value

        captureEngine = nil
        activeRecording = nil
        captureStatistics = outcome.statistics
        resetCaptureTiming()
        isCancelling = false

        if let deletionErrorMessage = outcome.deletionErrorMessage {
            fail(
                "Recording stopped, but its local files could not be removed: " +
                    deletionErrorMessage
            )
        } else {
            do {
                try stateMachine.transition(.cancel)
                phase = stateMachine.phase
                errorMessage = nil
                noticeMessage = "Recording cancelled."
            } catch {
                fail(error.localizedDescription)
            }
        }
        reloadHistory()
    }

    private func finishRecording(captureFailure: String?) async {
        guard isCaptureActive,
              !isCancelling,
              let engine = captureEngine,
              var recording = activeRecording
        else { return }
        capturePollTask?.cancel()
        capturePollTask = nil
        do {
            try stateMachine.transition(.stop)
            phase = stateMachine.phase
        } catch {
            fail(error.localizedDescription)
            return
        }

        let stoppedAt = Date()
        let stopOutcome = await Task.detached { () -> StopOutcome in
            do {
                return StopOutcome(statistics: try engine.stop(), errorMessage: nil)
            } catch {
                return StopOutcome(
                    statistics: engine.statistics(),
                    errorMessage: error.localizedDescription
                )
            }
        }.value
        captureEngine = nil
        captureStatistics = stopOutcome.statistics
        recording.stoppedAt = stoppedAt
        recording.captureEndedAt = stoppedAt
        recording.durationSeconds = activeElapsed(at: stoppedAt)
        recording.captureSummary = stopOutcome.statistics.summary
        recording.routeAfter = try? CaptureEngine.defaultAudioRoutes()
        if recording.captureSummary.totalDroppedFrames > 0 {
            recording.warnings.append(
                "Capture dropped \(recording.captureSummary.totalDroppedFrames) frames."
            )
        }
        if let before = recording.routeBefore,
           let after = recording.routeAfter,
           before != after {
            recording.warnings.append("The default audio route changed during recording.")
        }
        let failureMessage = captureFailure ?? stopOutcome.errorMessage
        if let failureMessage {
            recording.lastFailure = RecordingFailure(stage: .capture, message: failureMessage)
        }
        preparePublicationDestination(for: &recording)
        recording.captureStatus = .processing
        guard persistOrFail(recording) else {
            activeRecording = nil
            reloadHistory()
            return
        }

        let finalizeOutcome = await finalizeAndPublish(recording)

        guard let publication = finalizeOutcome.publication else {
            recording.captureStatus = .failed
            recording.lastFailure = RecordingFailure(
                stage: .finalization,
                message: finalizeOutcome.errorMessage ?? "Recording finalization failed."
            )
            _ = persistOrFail(recording)
            activeRecording = nil
            fail(recording.lastFailure?.message ?? "Recording finalization failed.")
            reloadHistory()
            return
        }

        recording.files.exportDirectory = publication.directoryURL.path
        recording.files.audio = publication.audioURL.path
        recording.files.audioBookmark = try? store.bookmark(for: publication.audioURL)
        recording.files.transcriptMarkdown = publication.directoryURL
            .appendingPathComponent("Transcript.md")
            .path
        recording.durationSeconds = publication.durationSeconds
        recording.warnings.append(contentsOf: finalizeOutcome.warnings)
        recording.captureStatus = failureMessage == nil ? .complete : .failed
        if let failureMessage {
            recording.lastFailure = RecordingFailure(stage: .capture, message: failureMessage)
        }
        guard persistOrFail(recording) else {
            activeRecording = nil
            reloadHistory()
            return
        }
        do {
            try store.removeCaptureArtifacts(for: recording)
        } catch {
            recording.warnings.append(
                "Temporary recovery files could not be removed: \(error.localizedDescription)"
            )
            _ = persistOrFail(recording)
        }
        if let failureMessage {
            activeRecording = nil
            fail("Audio was saved to \(publication.directoryURL.path). \(failureMessage)")
            reloadHistory()
            return
        }

        activeRecording = recording

        let resolvedAPIKey: String?
        do {
            resolvedAPIKey = try keychain.resolvedDeepgramAPIKey()
        } catch {
            recording.transcriptionStatus = .failed
            recording.lastFailure = RecordingFailure(
                stage: .transcription,
                message: error.localizedDescription
            )
            _ = persistOrFail(recording)
            activeRecording = nil
            fail(
                "Audio was saved to \(publication.directoryURL.path). " +
                    "The Deepgram key could not be read: \(error.localizedDescription)"
            )
            reloadHistory()
            return
        }
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else {
            recording.transcriptionStatus = .waitingForCredential
            guard persistOrFail(recording) else {
                activeRecording = nil
                reloadHistory()
                return
            }
            do {
                try stateMachine.transition(.finalized(transcriptionRequired: false))
            } catch {
                activeRecording = nil
                fail(error.localizedDescription)
                return
            }
            phase = stateMachine.phase
            activeRecording = nil
            noticeMessage =
                "Audio saved to \(publication.directoryURL.path). " +
                "Add a Deepgram key in Settings, then use Retry Transcription."
            reloadHistory()
            return
        }

        do {
            try stateMachine.transition(.finalized(transcriptionRequired: true))
        } catch {
            activeRecording = nil
            fail(error.localizedDescription)
            return
        }
        phase = stateMachine.phase
        await performTranscription(recording: recording, apiKey: apiKey)
    }

    func recoverFinalization(for recording: RecordingManifest) {
        guard !isBusy, FinalizationRecoveryPolicy.canRecover(recording) else { return }
        Task { await recoverFinalization(recording) }
    }

    private func recoverPendingFinalizations() async {
        let pending = recordings.filter { $0.captureStatus == .processing }
        for recording in pending {
            guard !Task.isCancelled else { return }
            await recoverFinalization(recording)
        }
    }

    private func recoverFinalization(_ original: RecordingManifest) async {
        guard !isBusy || phase == .processing,
              FinalizationRecoveryPolicy.canRecover(original)
        else { return }

        errorMessage = nil
        noticeMessage = nil
        stateMachine = RecorderStateMachine(phase: phase)
        do {
            try stateMachine.transition(.recoverFinalization)
            phase = stateMachine.phase
        } catch {
            fail(error.localizedDescription)
            return
        }

        var recording = original
        let interruptionMessage = recording.lastFailure?.message
        if original.captureStatus == .failed {
            recording.files.exportDirectory = nil
            recording.files.transcriptMarkdown = nil
            recording.files.transcriptBookmark = nil
        }
        preparePublicationDestination(for: &recording)
        recording.captureStatus = .processing
        guard persistOrFail(recording) else { return }
        activeRecording = recording

        let outcome = await finalizeAndPublish(recording)
        guard let publication = outcome.publication else {
            recording.captureStatus = .failed
            recording.lastFailure = RecordingFailure(
                stage: .finalization,
                message: outcome.errorMessage ?? "Recording recovery failed."
            )
            _ = persistOrFail(recording)
            activeRecording = nil
            fail(recording.lastFailure?.message ?? "Recording recovery failed.")
            reloadHistory()
            return
        }

        recording.files.exportDirectory = publication.directoryURL.path
        recording.files.audio = publication.audioURL.path
        recording.files.audioBookmark = try? store.bookmark(for: publication.audioURL)
        recording.files.transcriptMarkdown = publication.directoryURL
            .appendingPathComponent("Transcript.md").path
        recording.durationSeconds = publication.durationSeconds
        if original.captureStatus == .processing,
           original.captureEndedAt == nil {
            recording.captureEndedAt = recording.effectiveStartedAt.addingTimeInterval(
                publication.durationSeconds
            )
            recording.stoppedAt = recording.captureEndedAt
            if let captureEndedAt = recording.captureEndedAt {
                try? FileManager.default.setAttributes(
                    [.modificationDate: captureEndedAt],
                    ofItemAtPath: publication.audioURL.path
                )
            }
        }
        recording.captureStatus = .complete
        recording.transcriptionStatus = hasDeepgramKey ? .notStarted : .waitingForCredential
        recording.lastFailure = nil
        recording.warnings.append(contentsOf: outcome.warnings)
        if let interruptionMessage {
            recording.warnings.append("Recovered after interruption: \(interruptionMessage)")
        }
        guard persistOrFail(recording) else {
            activeRecording = nil
            reloadHistory()
            return
        }
        do {
            try store.removeCaptureArtifacts(for: recording)
        } catch {
            recording.warnings.append(
                "Temporary recovery files could not be removed: \(error.localizedDescription)"
            )
            _ = persistOrFail(recording)
        }

        activeRecording = nil
        do {
            try stateMachine.transition(.finalized(transcriptionRequired: false))
            phase = stateMachine.phase
        } catch {
            fail(error.localizedDescription)
            reloadHistory()
            return
        }
        noticeMessage = "Recovered audio to \(publication.directoryURL.path)."
        reloadHistory()
    }

    private func preparePublicationDestination(for recording: inout RecordingManifest) {
        if recording.files.exportDirectory == nil {
            recording.files.exportDirectory = audioExportService.publicationDirectory(
                for: recording,
                in: outputDirectory
            ).path
        }
        if recording.files.transcriptMarkdown == nil,
           let exportDirectory = recording.files.exportDirectory {
            recording.files.transcriptMarkdown = URL(fileURLWithPath: exportDirectory)
                .appendingPathComponent("Transcript.md").path
        }
    }

    private func finalizeAndPublish(_ recording: RecordingManifest) async -> FinalizeOutcome {
        let postProcessor = self.postProcessor
        let store = self.store
        return await Task.detached {
            do {
                let result = try postProcessor.process(recording: recording, store: store)
                return FinalizeOutcome(
                    publication: result.publication,
                    warnings: result.warnings,
                    errorMessage: nil
                )
            } catch {
                return FinalizeOutcome(
                    publication: nil,
                    warnings: [],
                    errorMessage: error.localizedDescription
                )
            }
        }.value
    }

    private func runTranscription(for recording: RecordingManifest) async {
        let resolvedAPIKey: String?
        do {
            resolvedAPIKey = try keychain.resolvedDeepgramAPIKey()
        } catch {
            activeRecording = nil
            fail(error.localizedDescription)
            return
        }
        guard let apiKey = resolvedAPIKey, !apiKey.isEmpty else {
            var updated = recording
            updated.transcriptionStatus = .waitingForCredential
            updated.lastFailure = RecordingFailure(
                stage: .transcription,
                message: "Add a Deepgram API key in Settings, then retry."
            )
            _ = persistOrFail(updated)
            activeRecording = nil
            fail(updated.lastFailure?.message ?? "A Deepgram API key is required.")
            reloadHistory()
            return
        }
        await performTranscription(recording: recording, apiKey: apiKey)
    }

    private func prepareAndTranscribeImportedAudio(_ audioURL: URL) async {
        do {
            guard FileManager.default.isReadableFile(atPath: audioURL.path) else {
                throw DeepgramError.unreadableAudio
            }
            let audio = try AVAudioFile(forReading: audioURL)
            guard audio.processingFormat.sampleRate > 0, audio.length > 0 else {
                throw DeepgramError.unreadableAudio
            }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            let values = try? audioURL.resourceValues(
                forKeys: [.creationDateKey, .contentModificationDateKey]
            )
            let startedAt: Date
            let timestampSource: RecordingTimestampSource
            if let creationDate = values?.creationDate {
                startedAt = creationDate
                timestampSource = .fileCreationDate
            } else if let modificationDate = values?.contentModificationDate {
                startedAt = modificationDate
                timestampSource = .fileModificationDate
            } else {
                startedAt = Date()
                timestampSource = .importTime
            }
            let transcriptURL = store.availableTranscriptURL(
                beside: audioURL,
                origin: .importedAudio
            )

            var recording = try store.createRecording(
                language: language,
                microphoneUID: "",
                microphoneName: "Imported audio",
                keyterms: activeKeyterms,
                now: startedAt
            )
            recording.origin = .importedAudio
            recording.timestampSource = timestampSource
            recording.captureStartedAt = startedAt
            recording.captureEndedAt = startedAt.addingTimeInterval(duration)
            recording.stoppedAt = recording.captureEndedAt
            recording.timeZoneIdentifier = TimeZone.current.identifier
            recording.durationSeconds = duration
            recording.captureStatus = .complete
            recording.files.exportDirectory = audioURL.deletingLastPathComponent().path
            recording.files.audio = audioURL.path
            recording.files.audioBookmark = try? store.bookmark(for: audioURL)
            recording.files.transcriptMarkdown = transcriptURL.path
            try store.save(recording)
            do {
                try store.removeCaptureArtifacts(for: recording)
            } catch {
                recording.warnings.append(
                    "Unused private working files could not be removed: \(error.localizedDescription)"
                )
                try store.save(recording)
            }
            activeRecording = recording
            reloadHistory()
            await runTranscription(for: recording)
        } catch {
            fail(error.localizedDescription)
            activeRecording = nil
            reloadHistory()
        }
    }

    private func performTranscription(recording: RecordingManifest, apiKey: String) async {
        do {
            let completed = try await transcriptionService.transcribe(
                recording: recording,
                store: store,
                apiKey: apiKey
            )
            do {
                try stateMachine.transition(.transcriptionSucceeded)
            } catch {
                fail(error.localizedDescription)
                activeRecording = nil
                reloadHistory()
                return
            }
            phase = stateMachine.phase
            errorMessage = nil
            if let transcriptURL = try? store.transcriptURL(for: completed) {
                if completed.effectiveOrigin == .nativeRecording {
                    noticeMessage = "Audio and transcript saved to \(transcriptURL.deletingLastPathComponent().path)."
                } else {
                    noticeMessage = "Transcript saved to \(transcriptURL.path)."
                }
            }
        } catch {
            let resolvedAudioURL = try? store.audioURL(for: recording)
            if recording.effectiveOrigin == .importedAudio, let resolvedAudioURL {
                fail(
                    "The source audio is unchanged at \(resolvedAudioURL.path). " +
                        "Transcription failed: \(error.localizedDescription)"
                )
            } else if let location = resolvedAudioURL?.deletingLastPathComponent().path {
                fail(
                    "Audio was saved to \(location). " +
                        "Transcription failed: \(error.localizedDescription)"
                )
            } else {
                fail("Transcription failed: \(error.localizedDescription)")
            }
        }
        activeRecording = nil
        reloadHistory()
    }

    private func startCapturePolling() {
        capturePollTask?.cancel()
        capturePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.isCaptureActive else { return }
                self.pollCapture()
            }
        }
    }

    private func pollCapture() {
        guard let captureEngine else { return }
        let statistics = captureEngine.statistics()
        if isMenuPresented ||
            statistics.summary.totalDroppedFrames != captureStatistics.summary.totalDroppedFrames ||
            statistics.fatalErrorCode != captureStatistics.fatalErrorCode {
            captureStatistics = statistics
        }
        let elapsed = floor(activeElapsed(at: Date()))
        if elapsed != elapsedSeconds {
            elapsedSeconds = elapsed
        }
        if let fatal = statistics.fatalErrorName, !fatalStopRequested, !isCancelling {
            fatalStopRequested = true
            Task { await finishRecording(captureFailure: fatal) }
        }
    }

    private func activeElapsed(at date: Date) -> TimeInterval {
        guard let recordingStartedAt else { return 0 }
        let currentPause = pausedAt.map { date.timeIntervalSince($0) } ?? 0
        return max(
            0,
            date.timeIntervalSince(recordingStartedAt) - accumulatedPausedSeconds - currentPause
        )
    }

    private func resetCaptureTiming() {
        recordingStartedAt = nil
        pausedAt = nil
        accumulatedPausedSeconds = 0
        elapsedSeconds = 0
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    private func fail(_ message: String) {
        noticeMessage = nil
        errorMessage = message
        do {
            try stateMachine.transition(.fail)
            phase = stateMachine.phase
        } catch {
            phase = .failed
            stateMachine = RecorderStateMachine(phase: .failed)
        }
    }

    @discardableResult
    private func persistOrFail(_ recording: RecordingManifest) -> Bool {
        do {
            try store.save(recording)
            return true
        } catch {
            fail("Unable to save recording status: \(error.localizedDescription)")
            return false
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func outputDirectoryIsLocal(_ url: URL) throws -> Bool {
        var existingURL = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existingURL.path),
              existingURL.path != "/" {
            existingURL.deleteLastPathComponent()
        }
        let values = try existingURL.resourceValues(forKeys: [.volumeIsLocalKey])
        return values.volumeIsLocal != false &&
            !FileManager.default.isUbiquitousItem(at: existingURL)
    }

    private enum Keys {
        static let microphoneUID = "selectedMicrophoneUID"
        static let language = "transcriptionLanguage"
        static let localSpeakerName = "localSpeakerName"
        static let keytermPromptingEnabled = "keytermPromptingEnabled"
        static let keytermsText = "keytermsText"
        static let outputDirectory = "outputDirectory"
    }

    private var parsedKeyterms: [String] {
        DeepgramKeyterms.parse(keytermsText)
    }

    private var activeKeyterms: [String] {
        guard keytermPromptingEnabled else { return [] }
        return DeepgramKeyterms.limited(parsedKeyterms)
    }
}
