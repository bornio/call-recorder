import Foundation

public enum RecordingLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case hebrew = "he"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: "English"
        case .hebrew: "Hebrew"
        }
    }
}

public enum CaptureStatus: String, Codable, Sendable {
    case recording
    case processing
    case complete
    case failed
}

public enum TranscriptionStatus: String, Codable, Sendable {
    case notStarted
    case waitingForCredential
    case transcribing
    case complete
    case failed
}

public enum RecordingOrigin: String, Codable, Sendable {
    case nativeRecording
    case importedAudio
}

public enum RecordingTimestampSource: String, Codable, Sendable {
    case captureClock = "capture_clock"
    case fileCreationDate = "file_creation_date"
    case fileModificationDate = "file_modification_date"
    case importTime = "import_time"
}

public enum RecordingTitleSource: String, Codable, Sendable {
    case calendar
    case user
}

public enum MeetingAssociationState: String, Codable, Sendable {
    case automatic
    case manual
    case unresolved
    case none
}

public enum FailureStage: String, Codable, Sendable {
    case capture
    case finalization
    case transcription
}

public struct RecordingFailure: Codable, Equatable, Sendable {
    public var stage: FailureStage
    public var message: String
    public var occurredAt: Date

    public init(stage: FailureStage, message: String, occurredAt: Date = Date()) {
        self.stage = stage
        self.message = message
        self.occurredAt = occurredAt
    }
}

public struct AudioRouteSnapshot: Codable, Equatable, Sendable {
    public var defaultInputDevice: UInt32
    public var defaultOutputDevice: UInt32

    public init(defaultInputDevice: UInt32, defaultOutputDevice: UInt32) {
        self.defaultInputDevice = defaultInputDevice
        self.defaultOutputDevice = defaultOutputDevice
    }
}

public struct CaptureSummary: Codable, Equatable, Sendable {
    public var systemFrames: UInt64
    public var microphoneFrames: UInt64
    public var systemDroppedFrames: UInt64
    public var microphoneDroppedFrames: UInt64
    public var systemSampleRate: Double
    public var microphoneSampleRate: Double

    public init(
        systemFrames: UInt64 = 0,
        microphoneFrames: UInt64 = 0,
        systemDroppedFrames: UInt64 = 0,
        microphoneDroppedFrames: UInt64 = 0,
        systemSampleRate: Double = 0,
        microphoneSampleRate: Double = 0
    ) {
        self.systemFrames = systemFrames
        self.microphoneFrames = microphoneFrames
        self.systemDroppedFrames = systemDroppedFrames
        self.microphoneDroppedFrames = microphoneDroppedFrames
        self.systemSampleRate = systemSampleRate
        self.microphoneSampleRate = microphoneSampleRate
    }

    public var totalDroppedFrames: UInt64 {
        systemDroppedFrames + microphoneDroppedFrames
    }
}

public struct RecordingFiles: Codable, Equatable, Sendable {
    public var systemCaptureDirectory: String
    public var microphoneCaptureDirectory: String
    public var audio: String?
    public var audioBookmark: Data?
    public var transcriptJSON: String?
    public var transcriptMarkdown: String?
    public var transcriptBookmark: Data?
    public var exportDirectory: String?

    public init(
        systemCaptureDirectory: String = "capture/system",
        microphoneCaptureDirectory: String = "capture/microphone",
        audio: String? = nil,
        audioBookmark: Data? = nil,
        transcriptJSON: String? = nil,
        transcriptMarkdown: String? = nil,
        transcriptBookmark: Data? = nil,
        exportDirectory: String? = nil
    ) {
        self.systemCaptureDirectory = systemCaptureDirectory
        self.microphoneCaptureDirectory = microphoneCaptureDirectory
        self.audio = audio
        self.audioBookmark = audioBookmark
        self.transcriptJSON = transcriptJSON
        self.transcriptMarkdown = transcriptMarkdown
        self.transcriptBookmark = transcriptBookmark
        self.exportDirectory = exportDirectory
    }
}

public struct SpeakerLabel: Codable, Equatable, Sendable {
    public var channel: Int
    public var speaker: Int
    public var displayName: String

    public init(channel: Int, speaker: Int, displayName: String) {
        self.channel = channel
        self.speaker = speaker
        self.displayName = displayName
    }
}

public struct RecordingManifest: Codable, Equatable, Identifiable, Sendable {
    public static let currentVersion = 1
    public static let defaultLocalSpeakerName = "Me"

    public var version: Int
    public var id: UUID
    public var createdAt: Date
    public var stoppedAt: Date?
    public var captureStartedAt: Date?
    public var captureEndedAt: Date?
    public var timeZoneIdentifier: String?
    public var durationSeconds: Double?
    public var origin: RecordingOrigin?
    public var timestampSource: RecordingTimestampSource?
    public var title: String?
    public var titleSource: RecordingTitleSource?
    public var meetingAssociationState: MeetingAssociationState?
    public var calendarCandidates: [CalendarEventCandidate]?
    public var calendarEventIdentifier: String?
    public var calendarTitle: String?
    public var calendarStartDate: Date?
    public var calendarEndDate: Date?
    public var calendarAttendeeNames: [String]?
    public var language: RecordingLanguage
    public var microphoneUID: String
    public var microphoneName: String
    public var localSpeakerName: String?
    public var speakerLabels: [SpeakerLabel]?
    public var keyterms: [String]?
    public var captureStatus: CaptureStatus
    public var transcriptionStatus: TranscriptionStatus
    public var transcriptionAttempts: Int
    public var files: RecordingFiles
    public var captureSummary: CaptureSummary
    public var routeBefore: AudioRouteSnapshot?
    public var routeAfter: AudioRouteSnapshot?
    public var warnings: [String]
    public var lastFailure: RecordingFailure?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        language: RecordingLanguage,
        microphoneUID: String,
        microphoneName: String,
        localSpeakerName: String? = nil,
        keyterms: [String]? = nil
    ) {
        version = Self.currentVersion
        self.id = id
        self.createdAt = createdAt
        stoppedAt = nil
        captureStartedAt = nil
        captureEndedAt = nil
        timeZoneIdentifier = nil
        durationSeconds = nil
        origin = .nativeRecording
        timestampSource = .captureClock
        title = nil
        titleSource = nil
        meetingAssociationState = nil
        calendarCandidates = nil
        calendarEventIdentifier = nil
        calendarTitle = nil
        calendarStartDate = nil
        calendarEndDate = nil
        calendarAttendeeNames = nil
        self.language = language
        self.microphoneUID = microphoneUID
        self.microphoneName = microphoneName
        self.localSpeakerName = localSpeakerName
        speakerLabels = nil
        self.keyterms = keyterms
        captureStatus = .recording
        transcriptionStatus = .notStarted
        transcriptionAttempts = 0
        files = RecordingFiles()
        captureSummary = CaptureSummary()
        routeBefore = nil
        routeAfter = nil
        warnings = []
        lastFailure = nil
    }

    public var displayTitle: String {
        if let title = Self.normalizedTitle(title) ?? Self.normalizedTitle(calendarTitle) {
            return title
        }
        if let importedSourceFilename {
            return URL(fileURLWithPath: importedSourceFilename)
                .deletingPathExtension()
                .lastPathComponent
        }
        return "Untitled recording"
    }

    public var effectiveMeetingAssociationState: MeetingAssociationState {
        if let meetingAssociationState { return meetingAssociationState }
        return calendarEventIdentifier == nil ? .none : .automatic
    }

    public var effectiveTitleSource: RecordingTitleSource? {
        if let titleSource { return titleSource }
        guard let normalizedTitle = Self.normalizedTitle(title) else { return nil }
        if normalizedTitle == Self.normalizedTitle(calendarTitle) { return .calendar }
        return .user
    }

    public var assignedCalendarEvent: CalendarEventCandidate? {
        guard let identifier = calendarEventIdentifier,
              let title = calendarTitle,
              let startDate = calendarStartDate,
              let endDate = calendarEndDate
        else { return nil }
        return CalendarEventCandidate(
            identifier: identifier,
            title: title,
            startDate: startDate,
            endDate: endDate,
            attendeeNames: calendarAttendeeNames ?? []
        )
    }

    public mutating func assignMeeting(
        _ event: CalendarEventCandidate,
        state: MeetingAssociationState,
        updateCalendarTitle: Bool
    ) {
        precondition(state == .automatic || state == .manual)
        let shouldUpdateTitle = updateCalendarTitle &&
            (title == nil || effectiveTitleSource == .calendar)
        calendarEventIdentifier = event.identifier
        calendarTitle = Self.normalizedTitle(event.title)
        calendarStartDate = event.startDate
        calendarEndDate = event.endDate
        calendarAttendeeNames = event.attendeeNames
        meetingAssociationState = state
        var candidates = calendarCandidates ?? []
        candidates.removeAll { $0.identifier == event.identifier }
        candidates.append(event)
        calendarCandidates = candidates.sorted { $0.startDate < $1.startDate }
        if shouldUpdateTitle {
            title = calendarTitle
            titleSource = title == nil ? nil : .calendar
        }
    }

    public mutating func markMeetingUnresolved(
        candidates: [CalendarEventCandidate]
    ) {
        clearAssignedMeeting()
        meetingAssociationState = .unresolved
        calendarCandidates = candidates.isEmpty ? nil : candidates
    }

    public mutating func clearMeetingAssociation(keepCandidates: Bool = false) {
        let shouldClearTitle = effectiveTitleSource == .calendar
        clearAssignedMeeting()
        meetingAssociationState = MeetingAssociationState.none
        if !keepCandidates { calendarCandidates = nil }
        if shouldClearTitle {
            title = nil
            titleSource = nil
        }
    }

    private mutating func clearAssignedMeeting() {
        calendarEventIdentifier = nil
        calendarTitle = nil
        calendarStartDate = nil
        calendarEndDate = nil
        calendarAttendeeNames = nil
    }

    public static func normalizedTitle(_ value: String?) -> String? {
        let words = (value ?? "").split(whereSeparator: { $0.isWhitespace })
        let normalized = words.joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(120))
    }

    public var importedSourceFilename: String? {
        guard effectiveOrigin == .importedAudio,
              let audioPath = files.audio
        else { return nil }
        let filename = URL(fileURLWithPath: audioPath).lastPathComponent
        return filename.isEmpty ? nil : filename
    }

    public var effectiveOrigin: RecordingOrigin {
        origin ?? .nativeRecording
    }

    public var effectiveTimestampSource: RecordingTimestampSource {
        timestampSource ?? (effectiveOrigin == .nativeRecording ? .captureClock : .importTime)
    }

    public var effectiveStartedAt: Date {
        captureStartedAt ?? createdAt
    }

    public var effectiveEndedAt: Date? {
        captureEndedAt ?? stoppedAt
    }

    public var effectiveLocalSpeakerName: String {
        Self.normalizedLocalSpeakerName(localSpeakerName)
    }

    public static func normalizedLocalSpeakerName(_ value: String?) -> String {
        let words = (value ?? "").split(whereSeparator: { $0.isWhitespace })
        let normalized = words.joined(separator: " ")
        guard !normalized.isEmpty else { return Self.defaultLocalSpeakerName }
        return String(normalized.prefix(64))
    }

    public func speakerDisplayName(channel: Int, speaker: Int?) -> String {
        if effectiveOrigin == .nativeRecording, channel == 1 {
            return effectiveLocalSpeakerName
        }
        let speaker = speaker ?? 0
        if let customName = speakerLabels?.first(where: {
            $0.channel == channel && $0.speaker == speaker
        }).flatMap({ Self.normalizedSpeakerName($0.displayName) }) {
            return customName
        }
        if effectiveOrigin == .importedAudio, channel > 0 {
            return "Channel \(channel) · Speaker \(speaker)"
        }
        return "Speaker \(speaker)"
    }

    public mutating func setSpeakerName(
        _ value: String?,
        channel: Int,
        speaker: Int?
    ) {
        let speaker = speaker ?? 0
        var labels = speakerLabels ?? []
        labels.removeAll { $0.channel == channel && $0.speaker == speaker }
        if let normalized = Self.normalizedSpeakerName(value) {
            labels.append(
                SpeakerLabel(channel: channel, speaker: speaker, displayName: normalized)
            )
        }
        speakerLabels = labels.isEmpty ? nil : labels.sorted {
            if $0.channel == $1.channel { return $0.speaker < $1.speaker }
            return $0.channel < $1.channel
        }
    }

    public static func normalizedSpeakerName(_ value: String?) -> String? {
        let words = (value ?? "").split(whereSeparator: { $0.isWhitespace })
        let normalized = words.joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(64))
    }

    public var effectiveKeyterms: [String] {
        DeepgramKeyterms.limited(keyterms ?? [])
    }

    public var hasFailure: Bool {
        lastFailure != nil ||
            captureStatus == .failed ||
            transcriptionStatus == .failed
    }

    public var isProcessing: Bool {
        captureStatus == .processing || transcriptionStatus == .transcribing
    }

    public var requiresAttention: Bool {
        transcriptionStatus == .waitingForCredential ||
            hasFailure ||
            captureHealthSummary != nil
    }

    public func audioStatusText(hasRecoveryAudio: Bool) -> String {
        switch captureStatus {
        case .recording:
            return "Recording"
        case .processing:
            return "Finishing"
        case .complete:
            return files.audio == nil ? "Unavailable" : "Saved"
        case .failed:
            if files.audio != nil { return "Saved with errors" }
            return hasRecoveryAudio ? "Recovery retained" : "Failed"
        }
    }

    public var transcriptStatusText: String {
        switch transcriptionStatus {
        case .notStarted: return "Waiting"
        case .waitingForCredential: return "Needs key"
        case .transcribing: return "Transcribing"
        case .complete: return "Ready"
        case .failed: return "Failed"
        }
    }

    public var captureHealthSummary: String? {
        var messages: [String] = []
        let droppedFrames = captureSummary.totalDroppedFrames
        if droppedFrames > 0 {
            let frameDescription = droppedFrames == 1
                ? "1 audio frame was"
                : "\(droppedFrames) audio frames were"
            messages.append("\(frameDescription) dropped. Audio may contain gaps.")
        }

        if let before = routeBefore, let after = routeAfter {
            switch (
                before.defaultInputDevice != after.defaultInputDevice,
                before.defaultOutputDevice != after.defaultOutputDevice
            ) {
            case (true, true):
                messages.append("The default microphone and output device changed during recording.")
            case (true, false):
                messages.append("The default microphone changed during recording.")
            case (false, true):
                messages.append("The default output device changed during recording.")
            case (false, false):
                break
            }
        }

        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
}

public enum CaptureSessionState: String, Sendable {
    case ready
    case starting
    case recording
    case paused
    case stopping
}

public enum CaptureSessionEvent: Equatable, Sendable {
    case startRequested
    case captureStarted
    case pause
    case resume
    case stopRequested
    case stopped
    case startFailed
}

public enum CaptureSessionStateError: Error, Equatable, Sendable {
    case invalidTransition(from: CaptureSessionState, event: CaptureSessionEvent)
}

public struct CaptureSessionStateMachine: Sendable {
    public private(set) var state: CaptureSessionState

    public init(state: CaptureSessionState = .ready) {
        self.state = state
    }

    public mutating func transition(_ event: CaptureSessionEvent) throws {
        let next: CaptureSessionState? = switch (state, event) {
        case (.ready, .startRequested): .starting
        case (.starting, .captureStarted): .recording
        case (.starting, .startFailed): .ready
        case (.recording, .pause): .paused
        case (.paused, .resume): .recording
        case (.recording, .stopRequested), (.paused, .stopRequested): .stopping
        case (.stopping, .stopped): .ready
        default: nil
        }
        guard let next else {
            throw CaptureSessionStateError.invalidTransition(from: state, event: event)
        }
        state = next
    }
}
