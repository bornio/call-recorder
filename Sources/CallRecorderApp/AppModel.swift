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

private struct CancelOutcome: Sendable {
    var statistics: CaptureLiveStatistics
    var deletionErrorMessage: String?
}

struct CaptureIssue {
    enum Recovery {
        case appSettings
        case microphoneSettings
        case systemAudioSettings
    }

    var message: String
    var recovery: Recovery? = nil
}

enum DeepgramCredentialSource: Equatable {
    case none
    case keychain
    case environment
}

private struct ImportedAudioMetadata: Sendable {
    var duration: TimeInterval
    var startedAt: Date
    var timestampSource: RecordingTimestampSource
}

private func inspectImportedAudio(at audioURL: URL) throws -> ImportedAudioMetadata {
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
    if let creationDate = values?.creationDate {
        return ImportedAudioMetadata(
            duration: duration,
            startedAt: creationDate,
            timestampSource: .fileCreationDate
        )
    }
    if let modificationDate = values?.contentModificationDate {
        return ImportedAudioMetadata(
            duration: duration,
            startedAt: modificationDate,
            timestampSource: .fileModificationDate
        )
    }
    return ImportedAudioMetadata(
        duration: duration,
        startedAt: Date(),
        timestampSource: .importTime
    )
}

@MainActor
final class AppModel: ObservableObject {
    static weak var shared: AppModel?
    static let automaticMicrophoneUID = "__automatic_microphone__"

    @Published private(set) var captureState: CaptureSessionState = .ready
    @Published private(set) var backgroundActivity: RecordingJobActivity?
    @Published private(set) var recordings: [RecordingManifest] = []
    @Published private(set) var microphones: [AudioInputDevice] = []
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var captureStatistics: CaptureLiveStatistics = .empty
    @Published private(set) var hasDeepgramKey = false
    @Published private(set) var hasStoredDeepgramKey = false
    @Published private(set) var deepgramCredentialSource: DeepgramCredentialSource = .none
    @Published private(set) var storageUsage: RecordingStorageUsage = .zero
    @Published private(set) var isRefreshingStorage = false
    @Published private(set) var isRefreshingHistory = false
    @Published private(set) var isPerformingStartupCleanup = true
    @Published private(set) var isForgettingHistory = false
    @Published private(set) var isCancelling = false
    @Published private(set) var isImportingAudio = false
    @Published private(set) var captureIssue: CaptureIssue?
    @Published private(set) var outputDirectoryErrorMessage: String?
    @Published private(set) var keychainErrorMessage: String?
    @Published private(set) var storageErrorMessage: String?
    @Published private(set) var unseenTranscriptCompletionID: UUID?
    @Published private(set) var isPreparingToTerminate = false
    @Published var historyErrorMessage: String?

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

    private var captureStateMachine = CaptureSessionStateMachine()
    private var captureEngine: CaptureEngine?
    private var activeCapture: RecordingManifest?
    private var recordingStartedAt: Date?
    private var pausedAt: Date?
    private var accumulatedPausedSeconds: TimeInterval = 0
    private var capturePollTask: Task<Void, Never>?
    private var fatalStopRequested = false
    private var isMenuPresented = false
    private var terminationCompletion: (@MainActor () -> Void)?
    @Published private var recoverableCaptureIDs: Set<UUID> = []
    @Published private var pendingFinalizationEligibilityIDs: Set<UUID> = []
    @Published private var localTranscriptRecoveryIDs: Set<UUID> = []
    @Published private var pendingTranscriptEligibilityIDs: Set<UUID> = []
    private var eligibilityGeneration = 0
    private var storageRefreshPending = false
    private let store: RecordingStore
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let audioExportService = AudioExportService()
    private let jobQueue: RecordingJobQueue

    var isCaptureActive: Bool {
        captureState == .recording || captureState == .paused
    }

    var canStartRecording: Bool {
        !isPreparingToTerminate &&
            !isForgettingHistory &&
            captureState == .ready &&
            selectedMicrophone != nil
    }

    var canChangeCaptureConfiguration: Bool {
        captureState == .ready
    }

    var canImportAudio: Bool {
        !isPreparingToTerminate &&
            !isForgettingHistory &&
            !isRefreshingHistory &&
            captureState == .ready &&
            !isImportingAudio
    }

    var importUnavailableReason: String? {
        if isPreparingToTerminate { return "Unavailable while the app is preparing to quit." }
        if isForgettingHistory { return "Available after private history is removed." }
        if isRefreshingHistory { return "Available after Recordings finishes refreshing." }
        if captureState != .ready { return "Available after the current recording ends." }
        if isImportingAudio { return "The selected audio is already being prepared." }
        return nil
    }

    var canForgetHistory: Bool {
        !isPreparingToTerminate &&
            captureState == .ready &&
            backgroundActivity == nil &&
            !isForgettingHistory &&
            !isImportingAudio &&
            !isRefreshingStorage &&
            !isRefreshingHistory &&
            !isPerformingStartupCleanup &&
            storageUsage.privateHistoryBytes > 0 &&
            pendingRecordingCount == 0
    }

    var forgetHistoryUnavailableReason: String? {
        if isForgettingHistory { return "Removing private app history…" }
        if isImportingAudio { return "Available after the selected audio finishes importing." }
        if isRefreshingStorage || isRefreshingHistory { return "Available after storage refresh finishes." }
        if isPerformingStartupCleanup { return "Available after startup cleanup finishes." }
        if storageUsage.privateHistoryBytes == 0 { return "No private app history to remove." }
        if isPreparingToTerminate { return "Unavailable while the app is preparing to quit." }
        if captureState != .ready { return "Available after the current recording ends." }
        if backgroundActivity != nil || pendingRecordingCount > 0 {
            return "Available after recordings finish processing."
        }
        return nil
    }

    var hasActiveTranscription: Bool {
        guard let backgroundActivity else { return false }
        if case .transcribing = backgroundActivity { return true }
        return false
    }

    var requiresDeferredTermination: Bool {
        captureState != .ready || hasActiveTranscription
    }

    var activeCaptureID: UUID? {
        activeCapture?.id
    }

    var backgroundSummaryRecording: RecordingManifest? {
        if let id = backgroundActivity?.recordingID,
           let recording = recordings.first(where: { $0.id == id }) {
            return recording
        }
        let candidates = recordings.filter { $0.id != activeCapture?.id }
        if captureState == .ready,
           let actionable = candidates.first(where: Self.needsAttention) {
            return actionable
        }
        return candidates.first
    }

    var hasRecordingNeedingAttention: Bool {
        recordings.contains(where: Self.needsAttention)
    }

    var hasUnseenTranscriptCompletion: Bool {
        unseenTranscriptCompletionID != nil
    }

    var pendingRecordingCount: Int {
        recordings.filter { recording in
            recording.captureStatus == .processing ||
                (recording.captureStatus == .complete &&
                    (recording.transcriptionStatus == .notStarted ||
                        recording.transcriptionStatus == .transcribing))
        }.count
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
        outputDirectory = storedOutput.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? RecordingStore.defaultRootDirectory
        let store = RecordingStore(rootDirectory: RecordingStore.defaultHistoryDirectory)
        self.store = store
        let keychain = KeychainStore()
        self.keychain = keychain
        jobQueue = RecordingJobQueue(
            store: store,
            apiKeyProvider: { try keychain.resolvedDeepgramAPIKey() }
        )
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

        jobQueue.onChange = { [weak self] activity in
            guard let self else { return }
            backgroundActivity = activity
            reloadHistory()
            refreshStorageUsage()
            if let recordingID = activity?.recordingID,
               !isMenuPresented,
               recordings.first(where: { $0.id == recordingID })?.transcriptionStatus == .complete {
                unseenTranscriptCompletionID = recordingID
            }
            completePendingTerminationIfReady()
        }
        refreshMicrophones()
        refreshCredentialStatus()
        reloadHistory(recoverInterrupted: true, reconcile: true)

        let staleArtifactCutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let artifactDirectories = Set(
            [outputDirectory] + ((try? store.loadAll()) ?? []).compactMap { recording in
                guard recording.effectiveOrigin == .nativeRecording else { return nil }
                return recording.files.exportDirectory.map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                        .deletingLastPathComponent()
                }
            }
        )
        Task { [weak self] in
            await Task.detached(priority: .utility) {
                try? store.cleanupStalePrivateArtifacts(olderThan: staleArtifactCutoff)
                for directory in artifactDirectories {
                    try? AudioExportService.cleanupStaleArtifacts(
                        in: directory,
                        olderThan: staleArtifactCutoff
                    )
                }
            }.value
            guard let self else { return }
            isPerformingStartupCleanup = false
            refreshStorageUsage()
            if captureState == .ready {
                jobQueue.start()
            }
        }
    }

    func refreshMicrophones() {
        microphones = AudioDeviceService.inputDevices()
        if selectedMicrophoneUID != Self.automaticMicrophoneUID,
           !microphones.contains(where: { $0.uid == selectedMicrophoneUID }) {
            selectedMicrophoneUID = Self.automaticMicrophoneUID
        }
    }

    func reloadHistory(recoverInterrupted: Bool = false, reconcile: Bool = false) {
        do {
            if recoverInterrupted {
                try store.recoverInterruptedRecordings()
            }
            applyRecordings(reconcile ? try store.reconcileExternalFiles() : try store.loadAll())
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func refreshHistoryFromFinder() {
        guard !isRefreshingHistory else { return }
        guard backgroundActivity == nil, pendingRecordingCount == 0 else {
            reloadHistory()
            return
        }
        isRefreshingHistory = true
        let store = self.store
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try store.reconcileExternalFiles() }
            }.value
            isRefreshingHistory = false
            switch result {
            case .success(let recordings):
                applyRecordings(recordings)
                refreshStorageUsage()
                if hasDeepgramKey {
                    resumeWaitingTranscriptions()
                }
            case .failure(let error):
                historyErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyRecordings(_ loadedRecordings: [RecordingManifest]) {
        recordings = loadedRecordings
        recoverableCaptureIDs = []
        pendingFinalizationEligibilityIDs = Set(loadedRecordings.lazy.filter {
            FinalizationRecoveryPolicy.canRecover(
                $0,
                hasRecoverableCapture: true
            )
        }.map(\.id))
        localTranscriptRecoveryIDs = []
        pendingTranscriptEligibilityIDs = Set(loadedRecordings.lazy.filter {
            TranscriptionRetryPolicy.canRetry($0)
        }.map(\.id))
        if let unseenTranscriptCompletionID,
           !recordings.contains(where: {
               $0.id == unseenTranscriptCompletionID &&
                   $0.transcriptionStatus == .complete
           }) {
            self.unseenTranscriptCompletionID = nil
        }
        eligibilityGeneration += 1
        let generation = eligibilityGeneration
        let store = self.store
        Task {
            let result = await Task.detached(priority: .utility) {
                let recoverable = Set(loadedRecordings.lazy.filter { recording in
                    FinalizationRecoveryPolicy.canRecover(
                        recording,
                        hasRecoverableCapture: true
                    ) && store.hasClosedCaptureMetadata(for: recording)
                }.map(\.id))
                let localRetries = Set(loadedRecordings.lazy.filter { recording in
                    TranscriptionRetryPolicy.canRetry(recording) &&
                        store.hasValidRetainedTranscriptResponse(for: recording)
                }.map(\.id))
                return (recoverable, localRetries)
            }.value
            guard generation == eligibilityGeneration else { return }
            recoverableCaptureIDs = result.0
            pendingFinalizationEligibilityIDs = []
            localTranscriptRecoveryIDs = result.1
            pendingTranscriptEligibilityIDs = []
        }
    }

    func startRecording() {
        guard canStartRecording, transitionCapture(.startRequested) else { return }
        jobQueue.suspendNewWork()
        captureIssue = nil
        Task { await beginRecording() }
    }

    func stopRecording() {
        requestStop(captureFailure: nil)
    }

    func pauseRecording() {
        guard captureState == .recording, !isCancelling, let captureEngine else { return }
        do {
            try captureEngine.setPaused(true)
            do {
                try captureStateMachine.transition(.pause)
            } catch {
                try? captureEngine.setPaused(false)
                throw error
            }
            let now = Date()
            elapsedSeconds = floor(activeElapsed(at: now))
            pausedAt = now
            captureStatistics = captureEngine.statistics()
            captureState = captureStateMachine.state
            captureIssue = nil
        } catch {
            captureIssue = CaptureIssue(
                message: "Unable to pause recording: \(error.localizedDescription)"
            )
        }
    }

    func resumeRecording() {
        guard captureState == .paused, !isCancelling, let captureEngine else { return }
        do {
            try captureEngine.setPaused(false)
            do {
                try captureStateMachine.transition(.resume)
            } catch {
                try? captureEngine.setPaused(true)
                throw error
            }
            let now = Date()
            if let pausedAt {
                accumulatedPausedSeconds += now.timeIntervalSince(pausedAt)
            }
            self.pausedAt = nil
            captureState = captureStateMachine.state
            captureIssue = nil
        } catch {
            captureIssue = CaptureIssue(
                message: "Unable to resume recording: \(error.localizedDescription)"
            )
        }
    }

    func cancelRecording() {
        guard isCaptureActive, !isCancelling, let activeCapture else { return }
        do {
            try store.markDiscardRequested(for: activeCapture)
        } catch {
            captureIssue = CaptureIssue(
                message: "Unable to secure the discard request. Recording continues: \(error.localizedDescription)"
            )
            return
        }
        guard transitionCapture(.stopRequested) else { return }
        isCancelling = true
        Task { await discardActiveCapture() }
    }

    func setMenuPresented(_ presented: Bool) {
        isMenuPresented = presented
        if presented {
            unseenTranscriptCompletionID = nil
        }
        if presented, isCaptureActive, let captureEngine {
            captureStatistics = captureEngine.statistics()
        }
    }

    func handleSystemSleep() {
        guard isCaptureActive, !fatalStopRequested, !isCancelling else { return }
        fatalStopRequested = true
        requestStop(
            captureFailure: "The Mac went to sleep during recording. Audio completed before sleep was preserved."
        )
    }

    func retryTranscription(for original: RecordingManifest) {
        guard localTranscriptRecoveryIDs.contains(original.id) else { return }
        queueTranscription(for: original, discardingRetainedResponse: false)
    }

    func reuploadTranscription(for original: RecordingManifest) {
        queueTranscription(for: original, discardingRetainedResponse: true)
    }

    func transcriptionRetryIsLocal(for recording: RecordingManifest) -> Bool {
        localTranscriptRecoveryIDs.contains(recording.id)
    }

    func transcriptionRetryEligibilityIsPending(for recording: RecordingManifest) -> Bool {
        pendingTranscriptEligibilityIDs.contains(recording.id)
    }

    private func queueTranscription(
        for original: RecordingManifest,
        discardingRetainedResponse: Bool
    ) {
        guard !isPreparingToTerminate,
              captureState == .ready,
              !jobQueue.isWorking(on: original.id),
              TranscriptionRetryPolicy.canRetry(original),
              var recording = try? store.load(id: original.id)
        else { return }
        recording.transcriptionStatus = .notStarted
        if recording.lastFailure?.stage == .transcription {
            recording.lastFailure = nil
        }
        do {
            if discardingRetainedResponse &&
                store.expectsRetainedTranscriptResponse(for: recording) {
                try store.removeRetainedTranscriptResponse(for: recording)
                recording.files.transcriptJSON = nil
            }
            try store.save(recording)
            reloadHistory()
            jobQueue.wake()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func canRetryTranscription(for recording: RecordingManifest) -> Bool {
        !isPreparingToTerminate &&
            captureState == .ready &&
            !isRefreshingHistory &&
            !isPerformingStartupCleanup &&
            !pendingTranscriptEligibilityIDs.contains(recording.id) &&
            !jobQueue.isWorking(on: recording.id) &&
            TranscriptionRetryPolicy.canRetry(recording)
    }

    func shouldOfferTranscriptionRetry(for recording: RecordingManifest) -> Bool {
        !jobQueue.isWorking(on: recording.id) &&
            TranscriptionRetryPolicy.canRetry(recording)
    }

    var retryUnavailableReason: String? {
        if isPreparingToTerminate {
            return "The app is preparing to quit."
        }
        if captureState != .ready {
            return "Available after the current recording ends."
        }
        if isRefreshingHistory {
            return "Available after Recordings finishes refreshing."
        }
        if isPerformingStartupCleanup {
            return "Available after startup cleanup finishes."
        }
        return nil
    }

    func recoverFinalization(for original: RecordingManifest) {
        guard canRecoverFinalization(for: original),
              var recording = try? store.load(id: original.id)
        else { return }
        recording.files.audio = nil
        recording.files.audioBookmark = nil
        recording.files.exportDirectory = nil
        recording.files.transcriptMarkdown = nil
        recording.files.transcriptBookmark = nil
        preparePublicationDestination(for: &recording)
        recording.captureStatus = .processing
        do {
            try store.save(recording)
            reloadHistory()
            jobQueue.wake()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func canRecoverFinalization(for recording: RecordingManifest) -> Bool {
        !isPreparingToTerminate &&
            captureState == .ready &&
            !isRefreshingHistory &&
            !isPerformingStartupCleanup &&
            !pendingFinalizationEligibilityIDs.contains(recording.id) &&
            shouldOfferFinalizationRecovery(for: recording)
    }

    func shouldOfferFinalizationRecovery(for recording: RecordingManifest) -> Bool {
        !jobQueue.isWorking(on: recording.id) &&
            (pendingFinalizationEligibilityIDs.contains(recording.id) ||
                FinalizationRecoveryPolicy.canRecover(
                    recording,
                    hasRecoverableCapture: recoverableCaptureIDs.contains(recording.id)
                ))
    }

    func finalizationRecoveryEligibilityIsPending(
        for recording: RecordingManifest
    ) -> Bool {
        pendingFinalizationEligibilityIDs.contains(recording.id)
    }

    func canDelete(_ recording: RecordingManifest) -> Bool {
        !isPreparingToTerminate &&
            captureState == .ready &&
            !isRefreshingHistory &&
            !isPerformingStartupCleanup &&
            activeCapture?.id != recording.id &&
            !jobQueue.isWorking(on: recording.id)
    }

    func delete(_ recording: RecordingManifest) {
        guard canDelete(recording) else { return }
        do {
            var keptUnverifiedFinderFiles = false
            if recording.effectiveOrigin == .nativeRecording {
                let audioURL = try store.audioURL(for: recording)
                let transcriptURL = try store.transcriptURL(for: recording)
                let publicURLs = [audioURL, transcriptURL].compactMap { $0 }
                for url in publicURLs where FileManager.default.fileExists(atPath: url.path) {
                    let directory = url.deletingLastPathComponent()
                    if AudioExportService.publicationBelongs(
                        in: directory,
                        to: recording.id
                    ) {
                        try FileManager.default.removeItem(at: url)
                    } else {
                        keptUnverifiedFinderFiles = true
                    }
                }
                for exportedDirectory in Set(publicURLs.map { $0.deletingLastPathComponent() })
                where AudioExportService.publicationBelongs(
                    in: exportedDirectory,
                    to: recording.id
                ) {
                    try AudioExportService.removePublicationMarker(
                        in: exportedDirectory,
                        recordingID: recording.id
                    )
                    if (try? FileManager.default.contentsOfDirectory(
                        atPath: exportedDirectory.path
                    ))?.isEmpty == true {
                        try FileManager.default.removeItem(at: exportedDirectory)
                    }
                }
            }
            try store.delete(recording)
            reloadHistory()
            refreshStorageUsage()
            jobQueue.wake()
            if keptUnverifiedFinderFiles {
                historyErrorMessage = "History was removed, but Finder files were kept because Call Recorder could not verify their ownership."
            }
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func revealAudio(in recording: RecordingManifest) {
        do {
            guard let url = try store.audioURL(for: recording) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func revealTranscript(in recording: RecordingManifest) {
        do {
            guard let url = try store.transcriptURL(for: recording) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func chooseOutputDirectory() {
        guard canChangeCaptureConfiguration else { return }
        outputDirectoryErrorMessage = nil
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
                outputDirectoryErrorMessage = "Choose a local, non-cloud-synced folder so " +
                    "recording stays local during the call."
                return
            }
        } catch {
            outputDirectoryErrorMessage =
                "Unable to verify the selected folder: \(error.localizedDescription)"
            return
        }
        outputDirectory = url.standardizedFileURL
        defaults.set(outputDirectory.path, forKey: Keys.outputDirectory)
        outputDirectoryErrorMessage = nil
    }

    func chooseAudioForTranscription() {
        guard canImportAudio else { return }
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
        guard canImportAudio,
              let url = urls.first(where: { $0.isFileURL })
        else {
            return false
        }
        transcribeAudio(url)
        return true
    }

    func saveDeepgramKey(_ key: String) -> Bool {
        do {
            try keychain.saveDeepgramAPIKey(key)
            refreshCredentialStatus()
            keychainErrorMessage = nil
            return true
        } catch {
            keychainErrorMessage = error.localizedDescription
            return false
        }
    }

    func removeDeepgramKey() {
        do {
            try keychain.deleteDeepgramAPIKey()
            refreshCredentialStatus()
            keychainErrorMessage = nil
        } catch {
            keychainErrorMessage = error.localizedDescription
        }
    }

    func refreshCredentialStatus() {
        let environmentKey = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedKey: String?
        do {
            storedKey = try keychain.deepgramAPIKey()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            storedKey = nil
            keychainErrorMessage = error.localizedDescription
        }
        hasStoredDeepgramKey = storedKey?.isEmpty == false
        if environmentKey?.isEmpty == false {
            deepgramCredentialSource = .environment
        } else if hasStoredDeepgramKey {
            deepgramCredentialSource = .keychain
        } else {
            deepgramCredentialSource = .none
        }
        hasDeepgramKey = deepgramCredentialSource != .none
        if hasDeepgramKey {
            resumeWaitingTranscriptions()
        }
    }

    func refreshStorageUsage() {
        if isRefreshingStorage {
            storageRefreshPending = true
            return
        }
        guard !isForgettingHistory else { return }
        storageErrorMessage = nil
        isRefreshingStorage = true
        let store = self.store
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try store.storageUsage() }
            }.value
            isRefreshingStorage = false
            switch result {
            case .success(let usage):
                storageUsage = usage
            case .failure(let error):
                storageErrorMessage = error.localizedDescription
            }
            if storageRefreshPending {
                storageRefreshPending = false
                refreshStorageUsage()
            }
        }
    }

    func recoveryBytes(for recording: RecordingManifest) -> Int64 {
        storageUsage.recoveryBytesByRecordingID[recording.id] ?? 0
    }

    func openAppDataFolder() {
        storageErrorMessage = nil
        let directory = store.rootDirectory.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(directory) {
                storageErrorMessage = "The app data folder could not be opened in Finder."
            }
        } catch {
            storageErrorMessage = error.localizedDescription
        }
    }

    func forgetHistoryKeepingExports() {
        guard canForgetHistory else { return }
        storageErrorMessage = nil
        isForgettingHistory = true
        let store = self.store
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try store.forgetAllHistory() }
            }.value
            isForgettingHistory = false
            switch result {
            case .success:
                reloadHistory()
                storageUsage = .zero
            case .failure(let error):
                storageErrorMessage = error.localizedDescription
            }
        }
    }

    func normalizeLocalSpeakerName() {
        localSpeakerName = RecordingManifest.normalizedLocalSpeakerName(localSpeakerName)
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
        jobQueue.shutdownImmediately()
        capturePollTask?.cancel()
        capturePollTask = nil
        if isCancelling {
            if let captureEngine {
                _ = try? captureEngine.stop()
            }
            if let activeCapture {
                try? store.delete(activeCapture)
            }
            captureEngine = nil
            activeCapture = nil
            resetCaptureTiming()
            return
        }
        guard let captureEngine, var recording = activeCapture else { return }
        let statistics = (try? captureEngine.stop()) ?? captureEngine.statistics()
        recording.captureStatus = .processing
        recording.stoppedAt = Date()
        recording.captureEndedAt = recording.stoppedAt
        recording.durationSeconds = activeElapsed(at: recording.stoppedAt ?? Date())
        recording.captureSummary = statistics.summary
        recording.lastFailure = RecordingFailure(
            stage: .finalization,
            message: "The app quit before post-recording finalization. " +
                "Closed capture chunks will be recovered on the next launch."
        )
        recording.routeAfter = try? CaptureEngine.defaultAudioRoutes()
        preparePublicationDestination(for: &recording)
        try? store.save(recording)
        self.captureEngine = nil
        activeCapture = nil
        resetCaptureTiming()
    }

    func prepareForTermination(completion: @escaping @MainActor () -> Void) {
        isPreparingToTerminate = true
        terminationCompletion = completion
        jobQueue.suspendNewWork()
        switch captureState {
        case .ready:
            completePendingTerminationIfReady()
        case .starting:
            _ = transitionCapture(.startFailed)
            completePendingTerminationIfReady()
        case .recording, .paused:
            requestStop(captureFailure: nil)
        case .stopping:
            break
        }
    }

    private func beginRecording() async {
        guard captureState == .starting else { return }
        refreshMicrophones()
        guard let microphone = selectedMicrophone else {
            captureStartFailed("No microphone is available.")
            return
        }
        outputDirectoryErrorMessage = nil
        do {
            guard try outputDirectoryIsLocal(outputDirectory) else {
                let message = "Choose a local, non-cloud-synced folder before recording."
                outputDirectoryErrorMessage = message
                captureStartFailed(
                    message,
                    recovery: .appSettings
                )
                return
            }
        } catch {
            let message = "Unable to verify the output folder: \(error.localizedDescription)"
            outputDirectoryErrorMessage = message
            captureStartFailed(
                message,
                recovery: .appSettings
            )
            return
        }
        guard await requestMicrophoneAccess() else {
            captureStartFailed(
                "Microphone access was denied. Grant access in System Settings, then try again.",
                recovery: .microphoneSettings
            )
            return
        }

        guard captureState == .starting else {
            resumeBackgroundWorkAfterCapture()
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
            recording.routeBefore = try? CaptureEngine.defaultAudioRoutes()
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
                recording.captureEndedAt = recording.stoppedAt
                recording.lastFailure = RecordingFailure(
                    stage: .capture,
                    message: "Recording did not start: \(error.localizedDescription)"
                )
                try? store.save(recording)
                try? store.markDiscardRequested(for: recording)
                try? store.delete(recording)
                throw error
            }

            let startedAt = Date()
            recording.captureStartedAt = startedAt
            recording.timeZoneIdentifier = TimeZone.current.identifier
            do {
                try store.save(recording)
                try captureStateMachine.transition(.captureStarted)
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
            activeCapture = recording
            recordingStartedAt = startedAt
            pausedAt = nil
            accumulatedPausedSeconds = 0
            elapsedSeconds = 0
            captureStatistics = engine.statistics()
            fatalStopRequested = false
            captureState = captureStateMachine.state
            startCapturePolling()
            reloadHistory()
        } catch {
            let message = error.localizedDescription
            let recovery: CaptureIssue.Recovery?
            if message.localizedCaseInsensitiveContains("System Audio Recording permission") {
                recovery = .systemAudioSettings
            } else if message.localizedCaseInsensitiveContains("Microphone permission") {
                recovery = .microphoneSettings
            } else {
                recovery = nil
            }
            captureStartFailed(message, recovery: recovery)
            reloadHistory()
        }
    }

    private func requestStop(captureFailure: String?) {
        guard isCaptureActive, !isCancelling,
              transitionCapture(.stopRequested)
        else { return }
        Task { await finishCapture(captureFailure: captureFailure) }
    }

    private func finishCapture(captureFailure: String?) async {
        guard captureState == .stopping,
              !isCancelling,
              let engine = captureEngine,
              var recording = activeCapture
        else { return }
        capturePollTask?.cancel()
        capturePollTask = nil

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
            recording.lastFailure = RecordingFailure(
                stage: .capture,
                message: failureMessage
            )
        }
        preparePublicationDestination(for: &recording)
        recording.captureStatus = .processing
        let saved = persist(recording)
        if !saved {
            reloadHistory(recoverInterrupted: true)
        }

        activeCapture = nil
        resetCaptureTiming()
        _ = transitionCapture(.stopped)
        resumeBackgroundWorkAfterCapture()
        reloadHistory()
        refreshStorageUsage()
        if saved {
            if let failureMessage {
                captureIssue = CaptureIssue(
                    message: "Recording stopped. Audio captured so far was secured locally. " +
                        failureMessage
                )
            } else {
                captureIssue = nil
            }
        }
        completePendingTerminationIfReady()
    }

    private func discardActiveCapture() async {
        guard captureState == .stopping,
              let engine = captureEngine,
              var recording = activeCapture
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
        activeCapture = nil
        captureStatistics = outcome.statistics
        resetCaptureTiming()
        isCancelling = false
        _ = transitionCapture(.stopped)
        resumeBackgroundWorkAfterCapture()
        reloadHistory()
        refreshStorageUsage()

        if let deletionErrorMessage = outcome.deletionErrorMessage {
            captureIssue = CaptureIssue(
                message: "Recording stopped, but its local files could not be removed: " +
                    deletionErrorMessage
            )
        } else {
            captureIssue = nil
        }
        completePendingTerminationIfReady()
    }

    private func transcribeAudio(_ url: URL) {
        guard url.isFileURL, canImportAudio else { return }
        isImportingAudio = true
        historyErrorMessage = nil
        Task { await prepareImportedAudio(url) }
    }

    private func prepareImportedAudio(_ audioURL: URL) async {
        defer { isImportingAudio = false }
        do {
            let metadata = try await Task.detached(priority: .userInitiated) {
                try inspectImportedAudio(at: audioURL)
            }.value
            let transcriptURL = store.availableTranscriptURL(
                beside: audioURL,
                origin: .importedAudio
            )

            var recording = try store.createRecording(
                language: language,
                microphoneUID: "",
                microphoneName: "Imported audio",
                keyterms: activeKeyterms,
                now: metadata.startedAt
            )
            recording.origin = .importedAudio
            recording.timestampSource = metadata.timestampSource
            recording.captureStartedAt = metadata.startedAt
            recording.captureEndedAt = metadata.startedAt.addingTimeInterval(metadata.duration)
            recording.stoppedAt = recording.captureEndedAt
            recording.timeZoneIdentifier = TimeZone.current.identifier
            recording.durationSeconds = metadata.duration
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
            reloadHistory()
            refreshStorageUsage()
            jobQueue.wake()
        } catch {
            historyErrorMessage = error.localizedDescription
            reloadHistory()
        }
    }

    private func resumeWaitingTranscriptions() {
        guard !isRefreshingHistory else { return }
        do {
            for var recording in try store.loadAll()
            where recording.captureStatus == .complete &&
                recording.transcriptionStatus == .waitingForCredential {
                recording.transcriptionStatus = .notStarted
                if recording.lastFailure?.stage == .transcription {
                    recording.lastFailure = nil
                }
                try store.save(recording)
            }
            reloadHistory()
            jobQueue.wake()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    private func preparePublicationDestination(for recording: inout RecordingManifest) {
        if recording.files.exportDirectory == nil {
            let reservedPaths = Set(
                ((try? store.loadAll()) ?? [])
                    .filter { $0.id != recording.id }
                    .compactMap { $0.files.exportDirectory }
                    .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            )
            recording.files.exportDirectory = audioExportService.publicationDirectory(
                for: recording,
                in: outputDirectory,
                reservedPaths: reservedPaths
            ).path
        }
        if recording.files.transcriptMarkdown == nil,
           let exportDirectory = recording.files.exportDirectory {
            recording.files.transcriptMarkdown = URL(fileURLWithPath: exportDirectory)
                .appendingPathComponent("Transcript.md").path
        }
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
            requestStop(captureFailure: fatal)
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

    private func resumeBackgroundWorkAfterCapture() {
        if !isPreparingToTerminate, !isPerformingStartupCleanup {
            jobQueue.captureDidEnd()
        }
    }

    private func completePendingTerminationIfReady() {
        guard isPreparingToTerminate,
              captureState == .ready,
              !hasActiveTranscription
        else { return }
        let completion = terminationCompletion
        terminationCompletion = nil
        completion?()
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

    private func captureStartFailed(
        _ message: String,
        recovery: CaptureIssue.Recovery? = nil
    ) {
        if captureState == .starting {
            _ = transitionCapture(.startFailed)
        }
        captureIssue = CaptureIssue(message: message, recovery: recovery)
        resumeBackgroundWorkAfterCapture()
    }

    @discardableResult
    private func transitionCapture(_ event: CaptureSessionEvent) -> Bool {
        do {
            try captureStateMachine.transition(event)
            captureState = captureStateMachine.state
            return true
        } catch {
            captureIssue = CaptureIssue(message: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    private func persist(_ recording: RecordingManifest) -> Bool {
        do {
            try store.save(recording)
            return true
        } catch {
            captureIssue = CaptureIssue(
                message: "Unable to save recording status: \(error.localizedDescription)"
            )
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

    private static func needsAttention(_ recording: RecordingManifest) -> Bool {
        recording.lastFailure != nil ||
            recording.captureStatus == .failed ||
            recording.transcriptionStatus == .failed ||
            recording.transcriptionStatus == .waitingForCredential
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
