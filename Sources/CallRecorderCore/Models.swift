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
    public var language: RecordingLanguage
    public var microphoneUID: String
    public var microphoneName: String
    public var localSpeakerName: String?
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
        self.language = language
        self.microphoneUID = microphoneUID
        self.microphoneName = microphoneName
        self.localSpeakerName = localSpeakerName
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
        (captureStartedAt ?? createdAt).formatted(date: .abbreviated, time: .shortened)
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

    public var effectiveKeyterms: [String] {
        DeepgramKeyterms.limited(keyterms ?? [])
    }

    public var statusText: String {
        if captureStatus == .recording { return "Recording" }
        if captureStatus == .processing { return "Finishing audio" }
        if captureStatus == .failed { return "Capture failed" }
        switch transcriptionStatus {
        case .notStarted: return "Waiting to transcribe"
        case .waitingForCredential: return "Needs Deepgram key"
        case .transcribing: return "Transcribing"
        case .complete: return "Transcript ready"
        case .failed: return "Transcription failed"
        }
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
