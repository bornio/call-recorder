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

private struct TranscriptCacheEntry: Equatable, Sendable {
    var fingerprint: TranscriptFileFingerprint?
    var document: TranscriptDocument?
}

private actor TranscriptDocumentLoader {
    private var entries: [UUID: TranscriptCacheEntry] = [:]

    func retainOnly(_ recordingIDs: Set<UUID>) {
        entries = entries.filter { recordingIDs.contains($0.key) }
    }

    func load(
        _ recording: RecordingManifest,
        from store: RecordingStore
    ) -> TranscriptCacheEntry? {
        for _ in 0..<2 {
            guard !Task.isCancelled else { return nil }
            let fingerprint = try? store.retainedTranscriptFingerprint(for: recording)
            if let cached = entries[recording.id],
               cached.fingerprint == fingerprint {
                return cached
            }
            let document = fingerprint == nil
                ? nil
                : try? store.transcriptDocument(for: recording)
            guard !Task.isCancelled else { return nil }
            let finalFingerprint = try? store.retainedTranscriptFingerprint(for: recording)
            guard fingerprint == finalFingerprint else { continue }
            let entry = TranscriptCacheEntry(
                fingerprint: fingerprint,
                document: document
            )
            entries[recording.id] = entry
            return entry
        }
        return nil
    }
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

private enum DevelopmentCredentialAccessError: LocalizedError, Sendable {
    case persistenceDisabled

    var errorDescription: String? {
        "Keychain storage is disabled in development builds."
    }
}

private struct DeepgramCredentialAccess: Sendable {
    let supportsPersistence: Bool
    let resolvedAPIKey: @Sendable () throws -> String?
    let storedAPIKey: @Sendable () throws -> String?
    let saveAPIKey: @Sendable (String) throws -> Void
    let removeAPIKey: @Sendable () throws -> Void

    static func keychainBacked() -> Self {
        let keychain = KeychainStore()
        return Self(
            supportsPersistence: true,
            resolvedAPIKey: { try keychain.resolvedDeepgramAPIKey() },
            storedAPIKey: { try keychain.deepgramAPIKey() },
            saveAPIKey: { try keychain.saveDeepgramAPIKey($0) },
            removeAPIKey: { try keychain.deleteDeepgramAPIKey() }
        )
    }

    static var keychainFreeDevelopment: Self {
        Self(
            supportsPersistence: false,
            resolvedAPIKey: {
                let value = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            },
            storedAPIKey: { nil },
            saveAPIKey: { _ in throw DevelopmentCredentialAccessError.persistenceDisabled },
            removeAPIKey: { throw DevelopmentCredentialAccessError.persistenceDisabled }
        )
    }

    static var applicationDefault: Self {
        #if CALL_RECORDER_KEYCHAIN_FREE_DEV
        keychainFreeDevelopment
        #else
        keychainBacked()
        #endif
    }
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
    // MARK: Observable State

    static weak var shared: AppModel?
    static let automaticMicrophoneUID = "__automatic_microphone__"

    @Published private(set) var captureState: CaptureSessionState = .ready
    @Published private(set) var backgroundActivity: RecordingJobActivity?
    @Published private(set) var recordings: [RecordingManifest] = []
    @Published private(set) var transcriptDocuments: [UUID: TranscriptDocument] = [:]
    @Published private(set) var pendingTranscriptDocumentIDs: Set<UUID> = []
    @Published private(set) var microphones: [AudioInputDevice] = []
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var captureStatistics: CaptureLiveStatistics = .empty
    @Published private(set) var hasDeepgramKey = false
    @Published private(set) var hasStoredDeepgramKey = false
    @Published private(set) var deepgramCredentialSource: DeepgramCredentialSource = .none
    let canPersistDeepgramKey: Bool
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
    @Published private(set) var calendarSuggestionsEnabled = false
    @Published private(set) var calendarAccessState: CalendarAccessState = .notDetermined
    @Published private(set) var availableCalendars: [CalendarDescriptor] = []
    @Published private(set) var selectedCalendarIDs: Set<String> = []
    @Published private(set) var calendarCandidates: [CalendarEventCandidate] = []
    @Published private(set) var calendarSuggestion: CalendarEventCandidate?
    @Published private(set) var calendarSelectionNeedsReview = false
    @Published private(set) var calendarChoiceWasMade = false
    @Published private(set) var meetingChoicesByRecordingID: [UUID: [CalendarEventCandidate]] = [:]
    @Published private(set) var isRefreshingCalendar = false
    @Published private(set) var calendarErrorMessage: String?
    @Published private(set) var recordingTitle = ""
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

    // MARK: Internal State and Services

    private var captureStateMachine = CaptureSessionStateMachine()
    private var captureEngine: CaptureEngine?
    private var activeCapture: RecordingManifest?
    private var recordingStartedAt: Date?
    private var pausedAt: Date?
    private var accumulatedPausedSeconds: TimeInterval = 0
    private var capturePollTask: Task<Void, Never>?
    private var startupCleanupTask: Task<Void, Never>?
    private var microphoneRefreshTask: Task<Void, Never>?
    private var backgroundHistoryReloadTask: Task<Void, Never>?
    private var historyRefreshTask: Task<Void, Never>?
    private var importedAudioTask: Task<Void, Never>?
    private var forgetHistoryTask: Task<Void, Never>?
    private var storageRefreshTask: Task<Void, Never>?
    private var fatalStopRequested = false
    private var isMenuPresented = false
    private var isHistoryPresented = false
    private var terminationCompletion: (@MainActor () -> Void)?
    @Published private var recoverableCaptureIDs: Set<UUID> = []
    @Published private var pendingFinalizationEligibilityIDs: Set<UUID> = []
    @Published private var localTranscriptRecoveryIDs: Set<UUID> = []
    @Published private var pendingTranscriptEligibilityIDs: Set<UUID> = []
    private var eligibilityGeneration = 0
    private var transcriptLoadGeneration = 0
    private var backgroundHistoryReloadGeneration = 0
    private var calendarRefreshGeneration = 0
    private var meetingChoicesGeneration = 0
    private let transcriptLoader = TranscriptDocumentLoader()
    private var transcriptLoadTask: Task<Void, Never>?
    private var transcriptPriorityLoadTask: Task<Void, Never>?
    private var eligibilityTask: Task<Void, Never>?
    private var calendarRefreshTask: Task<Void, Never>?
    private var meetingChoicesTask: Task<Void, Never>?
    private var storageRefreshPending = false
    private var calendarPrefilledTitle: String?
    private var calendarContextRefreshedAt: Date?
    private var defaultInputDeviceID: UInt32?
    private var recordingTitleWasEdited = false
    private var calendarContextEvents: [CalendarEventCandidate] = []
    private var pendingBackgroundCompletionIDs: Set<UUID> = []
    private let store: RecordingStore
    private let defaults: UserDefaults
    private let credentialAccess: DeepgramCredentialAccess
    private let calendarReader = CalendarReader()
    private let audioExportService = AudioExportService()
    private let jobQueue: RecordingJobQueue

    // MARK: Availability and Presentation

    private var hasPendingHistoryWork: Bool {
        isRefreshingHistory ||
            isImportingAudio ||
            isForgettingHistory ||
            backgroundHistoryReloadTask != nil ||
            historyRefreshTask != nil ||
            importedAudioTask != nil ||
            forgetHistoryTask != nil
    }

    private var hasPendingTerminationWork: Bool {
        backgroundActivity != nil ||
            hasPendingHistoryWork ||
            isPerformingStartupCleanup ||
            startupCleanupTask != nil ||
            microphoneRefreshTask != nil ||
            transcriptLoadTask != nil ||
            transcriptPriorityLoadTask != nil ||
            eligibilityTask != nil ||
            calendarRefreshTask != nil ||
            meetingChoicesTask != nil ||
            storageRefreshTask != nil
    }

    var isCaptureActive: Bool {
        captureState == .recording || captureState == .paused
    }

    var canStartRecording: Bool {
        !isPreparingToTerminate &&
            !hasPendingHistoryWork &&
            captureState == .ready &&
            selectedMicrophone != nil
    }

    var canChangeCaptureConfiguration: Bool {
        captureState == .ready
    }

    var canImportAudio: Bool {
        !isPreparingToTerminate &&
            !hasPendingHistoryWork &&
            captureState == .ready
    }

    var canRefreshHistory: Bool {
        !isPreparingToTerminate &&
            !hasPendingHistoryWork &&
            !isPerformingStartupCleanup &&
            captureState == .ready &&
            backgroundActivity == nil &&
            pendingRecordingCount == 0
    }

    var historyRefreshUnavailableReason: String? {
        if isRefreshingHistory || historyRefreshTask != nil {
            return "Checking Finder for changes."
        }
        if backgroundHistoryReloadTask != nil {
            return "Updating recordings after background work."
        }
        if isPreparingToTerminate { return "Unavailable while the app is preparing to quit." }
        if isForgettingHistory || forgetHistoryTask != nil {
            return "Available after private history is removed."
        }
        if isPerformingStartupCleanup { return "Available after startup cleanup finishes." }
        if isImportingAudio || importedAudioTask != nil {
            return "Available after the selected audio finishes importing."
        }
        if captureState != .ready { return "Available after the current recording ends." }
        if backgroundActivity != nil || pendingRecordingCount > 0 {
            return "Available after recordings finish processing."
        }
        return nil
    }

    var importUnavailableReason: String? {
        if isPreparingToTerminate { return "Unavailable while the app is preparing to quit." }
        if backgroundHistoryReloadTask != nil {
            return "Available after Recordings finishes updating."
        }
        if isForgettingHistory || forgetHistoryTask != nil {
            return "Available after private history is removed."
        }
        if isRefreshingHistory || historyRefreshTask != nil {
            return "Available after Recordings finishes refreshing."
        }
        if captureState != .ready { return "Available after the current recording ends." }
        if isImportingAudio || importedAudioTask != nil {
            return "The selected audio is already being prepared."
        }
        return nil
    }

    var canForgetHistory: Bool {
        !isPreparingToTerminate &&
            captureState == .ready &&
            backgroundActivity == nil &&
            !hasPendingHistoryWork &&
            !isRefreshingStorage &&
            !isPerformingStartupCleanup &&
            storageUsage.privateHistoryBytes > 0 &&
            pendingRecordingCount == 0
    }

    var forgetHistoryUnavailableReason: String? {
        if isForgettingHistory || forgetHistoryTask != nil {
            return "Removing private app history…"
        }
        if backgroundHistoryReloadTask != nil {
            return "Available after Recordings finishes updating."
        }
        if isImportingAudio || importedAudioTask != nil {
            return "Available after the selected audio finishes importing."
        }
        if isRefreshingStorage || isRefreshingHistory || historyRefreshTask != nil {
            return "Available after storage refresh finishes."
        }
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
        captureState != .ready || hasPendingTerminationWork
    }

    var backgroundSummaryRecording: RecordingManifest? {
        if let id = backgroundActivity?.recordingID,
           let recording = recordings.first(where: { $0.id == id }) {
            return recording
        }
        let candidates = recordings.filter { $0.id != activeCapture?.id }
        if captureState == .ready,
           let actionable = candidates.first(where: \.requiresAttention) {
            return actionable
        }
        return candidates.first
    }

    var hasRecordingNeedingAttention: Bool {
        recordings.contains(where: \.requiresAttention)
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
        AudioDeviceService.preferredInputDevice(
            from: microphones,
            defaultDeviceID: defaultInputDeviceID
        )
    }

    var automaticMicrophoneLabel: String {
        if let microphone = automaticMicrophone {
            let reason: String
            if microphone.isInUse {
                reason = "in use"
            } else if microphone.id == defaultInputDeviceID {
                reason = "system default"
            } else {
                reason = "available"
            }
            return "Automatic — \(microphone.name) (\(reason))"
        }
        return "Automatic"
    }

    // MARK: Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedOutput = defaults.string(forKey: Keys.outputDirectory)
        outputDirectory = storedOutput.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? RecordingStore.defaultRootDirectory
        let store = RecordingStore(rootDirectory: RecordingStore.defaultHistoryDirectory)
        self.store = store
        let credentialAccess = DeepgramCredentialAccess.applicationDefault
        self.credentialAccess = credentialAccess
        canPersistDeepgramKey = credentialAccess.supportsPersistence
        jobQueue = RecordingJobQueue(
            store: store,
            apiKeyProvider: credentialAccess.resolvedAPIKey
        )
        language = RecordingLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? ""
        ) ?? .english
        localSpeakerName = RecordingManifest.normalizedLocalSpeakerName(
            defaults.string(forKey: Keys.localSpeakerName)
        )
        keytermPromptingEnabled = defaults.bool(forKey: Keys.keytermPromptingEnabled)
        keytermsText = defaults.string(forKey: Keys.keytermsText) ?? ""
        calendarSuggestionsEnabled = defaults.bool(forKey: Keys.calendarSuggestionsEnabled)
        selectedCalendarIDs = Set(
            defaults.stringArray(forKey: Keys.selectedCalendarIDs) ?? []
        )
        selectedMicrophoneUID = defaults.string(forKey: Keys.microphoneUID)
            ?? Self.automaticMicrophoneUID
        Self.shared = self

        jobQueue.onChange = { [weak self] activity in
            guard let self else { return }
            let completedActivity = backgroundActivity
            backgroundActivity = activity
            guard activity == nil else { return }
            reloadHistoryAfterBackgroundChange(
                completedRecordingID: completedActivity?.recordingID
            )
            refreshStorageUsage()
            completePendingTerminationIfReady()
        }
        refreshMicrophonesAsync()
        refreshCredentialStatus()
        reloadHistory(recoverInterrupted: true, reconcile: true)
        if calendarSuggestionsEnabled {
            refreshCalendarContext()
        }

        let staleArtifactCutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let artifactDirectories = Set(
            [outputDirectory] + recordings.compactMap { recording in
                guard recording.effectiveOrigin == .nativeRecording else { return nil }
                return recording.files.exportDirectory.map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                        .deletingLastPathComponent()
                }
            }
        )
        startupCleanupTask = Task { [weak self] in
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
            startupCleanupTask = nil
            refreshStorageUsage()
            if !isPreparingToTerminate, captureState == .ready {
                jobQueue.start()
            }
            completePendingTerminationIfReady()
        }
    }

    // MARK: Microphones

    func refreshMicrophones() {
        microphones = AudioDeviceService.inputDevices()
        defaultInputDeviceID = AudioDeviceService.defaultInputDeviceID()
        normalizeSelectedMicrophone()
    }

    func refreshMicrophonesAsync() {
        guard !isPreparingToTerminate else { return }
        microphoneRefreshTask?.cancel()
        microphoneRefreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                (
                    devices: AudioDeviceService.inputDevices(),
                    defaultID: AudioDeviceService.defaultInputDeviceID()
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            microphones = snapshot.devices
            defaultInputDeviceID = snapshot.defaultID
            normalizeSelectedMicrophone()
            microphoneRefreshTask = nil
        }
    }

    private func normalizeSelectedMicrophone() {
        if selectedMicrophoneUID != Self.automaticMicrophoneUID,
           !microphones.contains(where: { $0.uid == selectedMicrophoneUID }) {
            selectedMicrophoneUID = Self.automaticMicrophoneUID
        }
    }

    // MARK: Capture Metadata and Calendar

    func setRecordingTitle(_ title: String) {
        recordingTitle = title
        recordingTitleWasEdited = true
    }

    func setCalendarSuggestionsEnabled(_ enabled: Bool) {
        guard canChangeCaptureConfiguration else { return }
        calendarSuggestionsEnabled = enabled
        defaults.set(enabled, forKey: Keys.calendarSuggestionsEnabled)
        if enabled {
            refreshCalendarContext(requestAccess: true)
        } else {
            calendarRefreshTask?.cancel()
            calendarRefreshTask = nil
            calendarRefreshGeneration += 1
            calendarContextRefreshedAt = nil
            calendarContextEvents = []
            calendarCandidates = []
            calendarSuggestion = nil
            calendarSelectionNeedsReview = false
            calendarChoiceWasMade = false
            availableCalendars = []
            calendarErrorMessage = nil
            isRefreshingCalendar = false
            clearCalendarPrefillIfNeeded()
        }
    }

    func setCalendar(_ calendar: CalendarDescriptor, selected: Bool) {
        guard canChangeCaptureConfiguration else { return }
        if selected {
            selectedCalendarIDs.insert(calendar.id)
        } else {
            selectedCalendarIDs.remove(calendar.id)
        }
        defaults.set(selectedCalendarIDs.sorted(), forKey: Keys.selectedCalendarIDs)
        defaults.set(true, forKey: Keys.calendarSelectionInitialized)
        scheduleCalendarContextRefresh(
            requestAccess: false,
            reloadCalendars: false,
            debounceMilliseconds: 200
        )
    }

    func calendarIsSelected(_ calendar: CalendarDescriptor) -> Bool {
        selectedCalendarIDs.contains(calendar.id)
    }

    func selectCalendarSuggestion(_ event: CalendarEventCandidate?) {
        guard canChangeCaptureConfiguration else { return }
        calendarSuggestion = event
        calendarSelectionNeedsReview = false
        calendarChoiceWasMade = true
        applyCalendarPrefill(event)
    }

    func refreshCalendarContext(
        requestAccess: Bool = false,
        reloadCalendars: Bool = true
    ) {
        scheduleCalendarContextRefresh(
            requestAccess: requestAccess,
            reloadCalendars: reloadCalendars,
            debounceMilliseconds: 0
        )
    }

    func refreshCalendarContextIfStale(maxAge: TimeInterval = 60) {
        guard calendarSuggestionsEnabled,
              canChangeCaptureConfiguration,
              calendarRefreshTask == nil,
              calendarContextRefreshedAt.map({ Date().timeIntervalSince($0) >= maxAge }) ?? true
        else { return }
        scheduleCalendarContextRefresh(
            requestAccess: false,
            reloadCalendars: availableCalendars.isEmpty,
            debounceMilliseconds: 0
        )
    }

    private func scheduleCalendarContextRefresh(
        requestAccess: Bool,
        reloadCalendars: Bool,
        debounceMilliseconds: UInt64
    ) {
        guard !isPreparingToTerminate,
              calendarSuggestionsEnabled,
              canChangeCaptureConfiguration
        else { return }
        calendarRefreshTask?.cancel()
        calendarRefreshGeneration += 1
        let generation = calendarRefreshGeneration
        isRefreshingCalendar = debounceMilliseconds == 0
        calendarErrorMessage = nil
        let reader = calendarReader
        calendarRefreshTask = Task { [weak self] in
            guard let self else { return }
            if debounceMilliseconds > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: debounceMilliseconds * 1_000_000
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      generation == calendarRefreshGeneration
                else { return }
                isRefreshingCalendar = true
            }
            do {
                var accessState = await reader.accessState()
                if requestAccess, accessState == .notDetermined {
                    _ = try await reader.requestFullAccess()
                    accessState = await reader.accessState()
                }
                try Task.checkCancellation()
                let calendars: [CalendarDescriptor]
                if accessState == .fullAccess,
                   reloadCalendars || availableCalendars.isEmpty {
                    calendars = await reader.availableCalendars()
                } else if accessState == .fullAccess {
                    calendars = availableCalendars
                } else {
                    calendars = []
                }
                try Task.checkCancellation()
                var selectedIDs = selectedCalendarIDs
                if accessState == .fullAccess,
                   !defaults.bool(forKey: Keys.calendarSelectionInitialized) {
                    selectedIDs = Set(calendars.map(\.id))
                    defaults.set(selectedIDs.sorted(), forKey: Keys.selectedCalendarIDs)
                    defaults.set(true, forKey: Keys.calendarSelectionInitialized)
                }
                let now = Date()
                let events = accessState == .fullAccess
                    ? await reader.eventsNearRecordingStart(
                        now: now,
                        selectedCalendarIDs: selectedIDs
                    )
                    : []
                try Task.checkCancellation()
                let match = CalendarEventMatchPolicy.matchAtRecordingStart(
                    from: events,
                    now: now
                )
                guard generation == calendarRefreshGeneration,
                      !Task.isCancelled
                else { return }
                calendarAccessState = accessState
                availableCalendars = calendars
                selectedCalendarIDs = selectedIDs
                calendarContextEvents = events
                calendarCandidates = match.candidates
                if !calendarChoiceWasMade {
                    calendarSuggestion = match.automaticSelection
                    calendarSelectionNeedsReview = match.needsReview
                    applyCalendarPrefill(match.automaticSelection)
                }
                calendarContextRefreshedAt = Date()
                isRefreshingCalendar = false
                calendarRefreshTask = nil
            } catch {
                let accessState = await reader.accessState()
                guard generation == calendarRefreshGeneration,
                      !Task.isCancelled
                else { return }
                calendarAccessState = accessState
                calendarContextEvents = []
                calendarCandidates = []
                if !calendarChoiceWasMade {
                    calendarSuggestion = nil
                    calendarSelectionNeedsReview = false
                    clearCalendarPrefillIfNeeded()
                }
                isRefreshingCalendar = false
                calendarErrorMessage = error.localizedDescription
                calendarRefreshTask = nil
            }
        }
    }

    func openCalendarPrivacySettings() {
        openPrivacySettings(anchor: "Privacy_Calendars")
    }

    private func applyCalendarPrefill(_ suggestion: CalendarEventCandidate?) {
        guard let suggestion,
              let proposedTitle = RecordingManifest.normalizedTitle(suggestion.title)
        else {
            clearCalendarPrefillIfNeeded()
            return
        }
        if !recordingTitleWasEdited {
            recordingTitle = proposedTitle
            calendarPrefilledTitle = proposedTitle
        }
    }

    private func clearCalendarPrefillIfNeeded() {
        if !recordingTitleWasEdited {
            recordingTitle = ""
        }
        calendarPrefilledTitle = nil
    }

    private func meetingChoiceAtRecordingStart(
        _ startedAt: Date
    ) -> (
        state: MeetingAssociationState,
        event: CalendarEventCandidate?,
        candidates: [CalendarEventCandidate]
    ) {
        guard calendarSuggestionsEnabled else { return (.none, nil, []) }
        let match = CalendarEventMatchPolicy.matchAtRecordingStart(
            from: calendarContextEvents,
            now: startedAt
        )
        if calendarChoiceWasMade {
            guard let calendarSuggestion else { return (.none, nil, []) }
            let candidates = mergedCalendarEvents(match.candidates + [calendarSuggestion])
            return (.manual, calendarSuggestion, candidates)
        }
        calendarCandidates = match.candidates
        calendarSuggestion = match.automaticSelection
        calendarSelectionNeedsReview = match.needsReview
        applyCalendarPrefill(match.automaticSelection)
        if let event = match.automaticSelection {
            return (.automatic, event, match.candidates)
        }
        if match.needsReview {
            return (.unresolved, nil, match.candidates)
        }
        return (.none, nil, match.candidates)
    }

    private func resetPendingMeetingChoice() {
        calendarContextEvents = []
        calendarCandidates = []
        calendarSuggestion = nil
        calendarSelectionNeedsReview = false
        calendarChoiceWasMade = false
    }

    // MARK: History and Transcript Index

    func reloadHistory(recoverInterrupted: Bool = false, reconcile: Bool = false) {
        invalidateBackgroundHistoryReload()
        do {
            if recoverInterrupted {
                try store.recoverInterruptedRecordings()
            }
            let loadedRecordings = reconcile
                ? try store.reconcileExternalFiles()
                : try store.loadAll()
            applyRecordings(loadedRecordings)
            publishPendingBackgroundCompletions(in: loadedRecordings)
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    private func reloadHistoryAfterBackgroundChange(completedRecordingID: UUID?) {
        guard !isPreparingToTerminate else { return }
        invalidateBackgroundHistoryReload()
        if let completedRecordingID {
            pendingBackgroundCompletionIDs.insert(completedRecordingID)
        }
        let generation = backgroundHistoryReloadGeneration
        let store = self.store
        backgroundHistoryReloadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try store.loadAll() }
            }.value
            guard let self,
                  !Task.isCancelled,
                  generation == backgroundHistoryReloadGeneration
            else { return }
            switch result {
            case .success(let recordings):
                applyRecordings(recordings)
                publishPendingBackgroundCompletions(in: recordings)
            case .failure(let error):
                historyErrorMessage = error.localizedDescription
            }
            backgroundHistoryReloadTask = nil
            completePendingTerminationIfReady()
        }
    }

    private func invalidateBackgroundHistoryReload() {
        backgroundHistoryReloadTask?.cancel()
        backgroundHistoryReloadTask = nil
        backgroundHistoryReloadGeneration += 1
    }

    private func publishPendingBackgroundCompletions(
        in loadedRecordings: [RecordingManifest]
    ) {
        if !isMenuPresented, !isHistoryPresented,
           let completedID = pendingBackgroundCompletionIDs.first(where: { id in
               loadedRecordings.first(where: { $0.id == id })?.transcriptionStatus == .complete
           }) {
            unseenTranscriptCompletionID = completedID
        }
        pendingBackgroundCompletionIDs = []
    }

    func refreshHistoryFromFinder() {
        guard canRefreshHistory else { return }
        isRefreshingHistory = true
        let store = self.store
        historyRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isRefreshingHistory = false
                historyRefreshTask = nil
                completePendingTerminationIfReady()
            }
            let result = await Task.detached(priority: .utility) {
                Result { try store.reconcileExternalFiles() }
            }.value
            switch result {
            case .success(let recordings):
                applyRecordings(recordings)
                refreshStorageUsage()
                if hasDeepgramKey {
                    resumeWaitingTranscriptions(allowDuringHistoryRefresh: true)
                }
            case .failure(let error):
                historyErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyRecordings(_ loadedRecordings: [RecordingManifest]) {
        recordings = loadedRecordings
        let loadedIDs = Set(loadedRecordings.map(\.id))
        let completedRecordings = loadedRecordings.filter {
            $0.transcriptionStatus == .complete
        }
        let completeTranscriptIDs = Set(completedRecordings.map(\.id))
        let retainedDocuments = transcriptDocuments.filter {
            completeTranscriptIDs.contains($0.key)
        }
        if retainedDocuments != transcriptDocuments {
            transcriptDocuments = retainedDocuments
        }
        meetingChoicesByRecordingID = meetingChoicesByRecordingID.filter {
            loadedIDs.contains($0.key)
        }
        transcriptLoadTask?.cancel()
        transcriptPriorityLoadTask?.cancel()
        transcriptLoadGeneration += 1
        let transcriptGeneration = transcriptLoadGeneration
        pendingTranscriptDocumentIDs = completeTranscriptIDs.subtracting(
            transcriptDocuments.keys
        )
        scheduleEligibilityRefresh(for: loadedRecordings)
        guard !isPreparingToTerminate, captureState == .ready else {
            acknowledgeMissingTranscriptCompletionIfNeeded()
            return
        }
        guard !completedRecordings.isEmpty else {
            pendingTranscriptDocumentIDs = []
            let loader = transcriptLoader
            transcriptLoadTask = Task {
                await loader.retainOnly([])
            }
            acknowledgeMissingTranscriptCompletionIfNeeded()
            return
        }
        let transcriptStore = store
        let loader = transcriptLoader
        transcriptLoadTask = Task { [weak self] in
            await loader.retainOnly(completeTranscriptIDs)
            var documents: [UUID: TranscriptDocument] = [:]
            for recording in completedRecordings {
                guard !Task.isCancelled else { return }
                if let entry = await loader.load(recording, from: transcriptStore),
                   let document = entry.document {
                    documents[recording.id] = document
                }
                await Task.yield()
            }
            guard let self,
                  !Task.isCancelled,
                  transcriptGeneration == transcriptLoadGeneration
            else { return }
            if documents != transcriptDocuments {
                transcriptDocuments = documents
            }
            pendingTranscriptDocumentIDs = []
            transcriptLoadTask = nil
        }
        acknowledgeMissingTranscriptCompletionIfNeeded()
    }

    private func scheduleEligibilityRefresh(
        for loadedRecordings: [RecordingManifest]
    ) {
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
        eligibilityTask?.cancel()
        eligibilityTask = nil
        eligibilityGeneration += 1
        guard !isPreparingToTerminate, captureState == .ready else { return }
        let generation = eligibilityGeneration
        let store = self.store
        eligibilityTask = Task.detached(priority: .utility) { [weak self] in
            var recoverable: Set<UUID> = []
            var localRetries: Set<UUID> = []
            for recording in loadedRecordings {
                guard !Task.isCancelled else { return }
                if FinalizationRecoveryPolicy.canRecover(
                    recording,
                    hasRecoverableCapture: true
                ), store.hasClosedCaptureMetadata(for: recording) {
                    recoverable.insert(recording.id)
                }
                if TranscriptionRetryPolicy.canRetry(recording),
                   store.hasValidRetainedTranscriptResponse(for: recording) {
                    localRetries.insert(recording.id)
                }
            }
            guard !Task.isCancelled else { return }
            await self?.finishEligibilityRefresh(
                recoverable: recoverable,
                localRetries: localRetries,
                generation: generation
            )
        }
    }

    private func finishEligibilityRefresh(
        recoverable: Set<UUID>,
        localRetries: Set<UUID>,
        generation: Int
    ) {
        guard generation == eligibilityGeneration else { return }
        recoverableCaptureIDs = recoverable
        pendingFinalizationEligibilityIDs = []
        localTranscriptRecoveryIDs = localRetries
        pendingTranscriptEligibilityIDs = []
        eligibilityTask = nil
    }

    private func acknowledgeMissingTranscriptCompletionIfNeeded() {
        if let unseenTranscriptCompletionID,
           !recordings.contains(where: {
               $0.id == unseenTranscriptCompletionID &&
                   $0.transcriptionStatus == .complete
           }) {
            acknowledgeTranscriptCompletion()
        }
    }

    // MARK: Capture Controls

    func startRecording() {
        guard canStartRecording, transitionCapture(.startRequested) else { return }
        calendarRefreshTask?.cancel()
        calendarRefreshTask = nil
        calendarRefreshGeneration += 1
        isRefreshingCalendar = false
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

    // MARK: Presentation Lifecycle

    func setMenuPresented(_ presented: Bool) {
        isMenuPresented = presented
        if presented {
            acknowledgeTranscriptCompletion()
        }
        if presented, isCaptureActive, let captureEngine {
            captureStatistics = captureEngine.statistics()
        }
    }

    func setHistoryPresented(_ presented: Bool) {
        isHistoryPresented = presented
        if presented {
            acknowledgeTranscriptCompletion()
        }
    }

    // MARK: Recording Detail Data

    func transcriptDocument(for recording: RecordingManifest) -> TranscriptDocument? {
        transcriptDocuments[recording.id]
    }

    func transcriptIsLoading(for recording: RecordingManifest) -> Bool {
        pendingTranscriptDocumentIDs.contains(recording.id)
    }

    func ensureTranscriptLoaded(for recording: RecordingManifest) {
        guard !isPreparingToTerminate,
              captureState == .ready,
              recording.transcriptionStatus == .complete,
              transcriptDocuments[recording.id] == nil,
              pendingTranscriptDocumentIDs.contains(recording.id)
        else { return }
        transcriptPriorityLoadTask?.cancel()
        let generation = transcriptLoadGeneration
        let loader = transcriptLoader
        let store = self.store
        let recordingID = recording.id
        transcriptPriorityLoadTask = Task { [weak self] in
            let entry = await loader.load(recording, from: store)
            guard let self,
                  !Task.isCancelled,
                  generation == transcriptLoadGeneration,
                  recordings.contains(where: {
                      $0.id == recordingID && $0.transcriptionStatus == .complete
                  })
            else { return }
            if let document = entry?.document,
               transcriptDocuments[recordingID] != document {
                transcriptDocuments[recordingID] = document
            }
            pendingTranscriptDocumentIDs.remove(recordingID)
            transcriptPriorityLoadTask = nil
        }
    }

    func resolvedAudioURL(for recording: RecordingManifest) -> URL? {
        try? store.audioURL(for: recording)
    }

    func meetingChoices(for recording: RecordingManifest) -> [CalendarEventCandidate] {
        mergedCalendarEvents(
            (recording.calendarCandidates ?? []) +
                (recording.assignedCalendarEvent.map { [$0] } ?? []) +
                (meetingChoicesByRecordingID[recording.id] ?? [])
        )
    }

    func refreshMeetingChoices(for recording: RecordingManifest) {
        guard !isPreparingToTerminate,
              calendarSuggestionsEnabled,
              let recordingEnd = recording.effectiveEndedAt
        else { return }
        meetingChoicesTask?.cancel()
        meetingChoicesGeneration += 1
        let generation = meetingChoicesGeneration
        let reader = calendarReader
        let selectedIDs = selectedCalendarIDs
        let recordingID = recording.id
        let recordingStart = recording.effectiveStartedAt
        meetingChoicesTask = Task { [weak self] in
            let events = await reader.eventsAroundRecording(
                startDate: recordingStart,
                endDate: recordingEnd,
                selectedCalendarIDs: selectedIDs
            )
            guard let self,
                  !Task.isCancelled,
                  generation == meetingChoicesGeneration,
                  recordings.contains(where: { $0.id == recordingID })
            else { return }
            meetingChoicesByRecordingID[recordingID] = mergedCalendarEvents(events)
            meetingChoicesTask = nil
        }
    }

    // MARK: Recording Metadata Actions

    func assignMeeting(
        _ event: CalendarEventCandidate,
        to original: RecordingManifest
    ) {
        guard canEditMetadata(for: original),
              var recording = try? store.load(id: original.id)
        else { return }
        recording.assignMeeting(event, state: .manual, updateCalendarTitle: true)
        do {
            try store.save(recording)
            synchronizePortableMetadata(for: recording)
            reloadHistory()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func clearMeetingAssociation(for original: RecordingManifest) {
        guard canEditMetadata(for: original),
              var recording = try? store.load(id: original.id)
        else { return }
        recording.clearMeetingAssociation(keepCandidates: false)
        do {
            try store.save(recording)
            synchronizePortableMetadata(for: recording)
            reloadHistory()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func renameRecording(_ original: RecordingManifest, to title: String) -> Bool {
        guard canEditMetadata(for: original) else { return false }
        do {
            var recording = try store.load(id: original.id)
            recording.title = RecordingManifest.normalizedTitle(title)
            recording.titleSource = recording.title == nil ? nil : .user
            try store.save(recording)
            synchronizePortableMetadata(for: recording)
            reloadHistory()
            return true
        } catch {
            historyErrorMessage = error.localizedDescription
            return false
        }
    }

    func renameSpeaker(
        in original: RecordingManifest,
        channel: Int,
        speaker: Int?,
        to name: String
    ) {
        guard canEditMetadata(for: original),
              !(original.effectiveOrigin == .nativeRecording && channel == 1),
              var recording = try? store.load(id: original.id)
        else { return }
        recording.setSpeakerName(name, channel: channel, speaker: speaker)
        do {
            try store.save(recording)
            reloadHistory()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func canEditMetadata(for recording: RecordingManifest) -> Bool {
        !isPreparingToTerminate &&
            !hasPendingHistoryWork &&
            !isPerformingStartupCleanup &&
            activeCapture?.id != recording.id &&
            !jobQueue.isWorking(on: recording.id)
    }

    private func synchronizePortableMetadata(for recording: RecordingManifest) {
        do {
            switch try store.synchronizeTranscriptMetadata(for: recording) {
            case .noFile:
                if recording.effectiveOrigin == .nativeRecording,
                   recording.files.audio != nil {
                    historyErrorMessage =
                        "The change was saved in app history, but Transcript.md is unavailable."
                }
            case .notOwned:
                historyErrorMessage =
                    "The change was saved in app history, but Transcript.md belongs to another recording."
            case .unchanged, .updated:
                break
            }
        } catch {
            historyErrorMessage =
                "The change was saved in app history, but Transcript.md could not be updated: "
                    + error.localizedDescription
        }
    }

    func copyTranscript(in recording: RecordingManifest) {
        do {
            guard let url = try store.transcriptURL(for: recording) else { return }
            let transcript = try String(contentsOf: url, encoding: .utf8)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    private func mergedCalendarEvents(
        _ events: [CalendarEventCandidate]
    ) -> [CalendarEventCandidate] {
        var identifiers: Set<String> = []
        return events.filter { identifiers.insert($0.identifier).inserted }.sorted {
            if $0.startDate == $1.startDate { return $0.endDate < $1.endDate }
            return $0.startDate < $1.startDate
        }
    }

    func dismissCaptureIssue() {
        captureIssue = nil
    }

    func handleSystemSleep() {
        guard isCaptureActive, !fatalStopRequested, !isCancelling else { return }
        fatalStopRequested = true
        requestStop(
            captureFailure: "The Mac went to sleep during recording. Audio completed before sleep was preserved."
        )
    }

    // MARK: Recovery and Deletion

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

    private func queueTranscription(
        for original: RecordingManifest,
        discardingRetainedResponse: Bool
    ) {
        guard !isPreparingToTerminate,
              !hasPendingHistoryWork,
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
            _ = try? store.synchronizeTranscriptMetadata(for: recording)
            reloadHistory()
            jobQueue.wake()
        } catch {
            historyErrorMessage = error.localizedDescription
        }
    }

    func canRetryTranscription(for recording: RecordingManifest) -> Bool {
        !isPreparingToTerminate &&
            captureState == .ready &&
            !hasPendingHistoryWork &&
            !isPerformingStartupCleanup &&
            !pendingTranscriptEligibilityIDs.contains(recording.id) &&
            !jobQueue.isWorking(on: recording.id) &&
            TranscriptionRetryPolicy.canRetry(recording)
    }

    func shouldOfferTranscriptionRetry(for recording: RecordingManifest) -> Bool {
        !hasPendingHistoryWork &&
            !jobQueue.isWorking(on: recording.id) &&
            TranscriptionRetryPolicy.canRetry(recording)
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
            !hasPendingHistoryWork &&
            !isPerformingStartupCleanup &&
            !pendingFinalizationEligibilityIDs.contains(recording.id) &&
            shouldOfferFinalizationRecovery(for: recording)
    }

    func shouldOfferFinalizationRecovery(for recording: RecordingManifest) -> Bool {
        !hasPendingHistoryWork &&
            !jobQueue.isWorking(on: recording.id) &&
            (pendingFinalizationEligibilityIDs.contains(recording.id) ||
                FinalizationRecoveryPolicy.canRecover(
                    recording,
                    hasRecoverableCapture: recoverableCaptureIDs.contains(recording.id)
                ))
    }

    func canDelete(_ recording: RecordingManifest) -> Bool {
        !isPreparingToTerminate &&
            captureState == .ready &&
            !hasPendingHistoryWork &&
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

    // MARK: Finder and Imports

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

    // MARK: Credentials and Storage

    func saveDeepgramKey(_ key: String) -> Bool {
        do {
            try credentialAccess.saveAPIKey(key)
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
            try credentialAccess.removeAPIKey()
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
            storedKey = try credentialAccess.storedAPIKey()?
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
        guard !isPreparingToTerminate else { return }
        if isRefreshingStorage {
            storageRefreshPending = true
            return
        }
        guard !isForgettingHistory else { return }
        storageErrorMessage = nil
        isRefreshingStorage = true
        let store = self.store
        storageRefreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try store.storageUsage() }
            }.value
            guard let self, !Task.isCancelled else { return }
            isRefreshingStorage = false
            storageRefreshTask = nil
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
        forgetHistoryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isForgettingHistory = false
                forgetHistoryTask = nil
                completePendingTerminationIfReady()
            }
            let result = await Task.detached(priority: .utility) {
                Result { try store.forgetAllHistory() }
            }.value
            switch result {
            case .success:
                reloadHistory()
                storageUsage = .zero
            case .failure(let error):
                storageErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Preferences and Privacy

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

    // MARK: Termination

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
        cancelDerivedRefreshesForTermination()
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

    private func cancelDerivedRefreshesForTermination() {
        microphoneRefreshTask?.cancel()
        microphoneRefreshTask = nil

        invalidateBackgroundHistoryReload()
        pendingBackgroundCompletionIDs = []

        transcriptLoadTask?.cancel()
        transcriptLoadTask = nil
        transcriptPriorityLoadTask?.cancel()
        transcriptPriorityLoadTask = nil
        transcriptLoadGeneration += 1

        eligibilityTask?.cancel()
        eligibilityTask = nil
        eligibilityGeneration += 1

        calendarRefreshTask?.cancel()
        calendarRefreshTask = nil
        calendarRefreshGeneration += 1
        isRefreshingCalendar = false

        meetingChoicesTask?.cancel()
        meetingChoicesTask = nil
        meetingChoicesGeneration += 1

        storageRefreshTask?.cancel()
        storageRefreshTask = nil
        storageRefreshPending = false
        isRefreshingStorage = false
    }

    // MARK: Capture Lifecycle Internals

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
            let meetingChoice = meetingChoiceAtRecordingStart(startedAt)
            recording.title = RecordingManifest.normalizedTitle(recordingTitle)
            if recording.title != nil {
                recording.titleSource = !recordingTitleWasEdited &&
                    recording.title == RecordingManifest.normalizedTitle(calendarPrefilledTitle)
                    ? .calendar
                    : .user
            }
            recording.calendarCandidates = meetingChoice.candidates.isEmpty
                ? nil
                : meetingChoice.candidates
            switch meetingChoice.state {
            case .automatic, .manual:
                if let event = meetingChoice.event {
                    recording.assignMeeting(
                        event,
                        state: meetingChoice.state,
                        updateCalendarTitle: false
                    )
                }
            case .unresolved:
                recording.markMeetingUnresolved(candidates: meetingChoice.candidates)
            case .none:
                recording.clearMeetingAssociation(keepCandidates: false)
            }
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
            recordingTitle = ""
            recordingTitleWasEdited = false
            calendarPrefilledTitle = nil
            resetPendingMeetingChoice()
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
        if recording.effectiveMeetingAssociationState == .unresolved,
           let recordingStart = recording.captureStartedAt,
           let resolvedEvent = CalendarEventMatchPolicy.resolveAfterRecording(
               from: recording.calendarCandidates ?? [],
               recordingStart: recordingStart,
               recordingEnd: stoppedAt
           ) {
            recording.assignMeeting(
                resolvedEvent,
                state: .automatic,
                updateCalendarTitle: true
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
        refreshCalendarContext(reloadCalendars: false)
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
        refreshCalendarContext(reloadCalendars: false)
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

    // MARK: Imported Audio Internals

    private func transcribeAudio(_ url: URL) {
        guard url.isFileURL, canImportAudio else { return }
        isImportingAudio = true
        historyErrorMessage = nil
        importedAudioTask = Task { [weak self] in
            await self?.prepareImportedAudio(url)
        }
    }

    private func prepareImportedAudio(_ audioURL: URL) async {
        defer {
            isImportingAudio = false
            importedAudioTask = nil
            completePendingTerminationIfReady()
        }
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

    private func resumeWaitingTranscriptions(
        allowDuringHistoryRefresh: Bool = false
    ) {
        guard allowDuringHistoryRefresh || !isRefreshingHistory else { return }
        do {
            for var recording in try store.loadAll()
            where recording.captureStatus == .complete &&
                recording.transcriptionStatus == .waitingForCredential {
                recording.transcriptionStatus = .notStarted
                if recording.lastFailure?.stage == .transcription {
                    recording.lastFailure = nil
                }
                try store.save(recording)
                _ = try? store.synchronizeTranscriptMetadata(for: recording)
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

    // MARK: Capture Monitoring

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
              !hasPendingTerminationWork
        else { return }
        let completion = terminationCompletion
        terminationCompletion = nil
        completion?()
    }

    private func acknowledgeTranscriptCompletion() {
        unseenTranscriptCompletionID = nil
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

    // MARK: Shared Helpers

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

    private enum Keys {
        static let microphoneUID = "selectedMicrophoneUID"
        static let language = "transcriptionLanguage"
        static let localSpeakerName = "localSpeakerName"
        static let keytermPromptingEnabled = "keytermPromptingEnabled"
        static let keytermsText = "keytermsText"
        static let outputDirectory = "outputDirectory"
        static let calendarSuggestionsEnabled = "calendarSuggestionsEnabled"
        static let selectedCalendarIDs = "selectedCalendarIDs"
        static let calendarSelectionInitialized = "calendarSelectionInitialized"
    }

    private var parsedKeyterms: [String] {
        DeepgramKeyterms.parse(keytermsText)
    }

    private var activeKeyterms: [String] {
        guard keytermPromptingEnabled else { return [] }
        return DeepgramKeyterms.limited(parsedKeyterms)
    }
}
