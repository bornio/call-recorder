import Foundation

public enum RecordingJobActivity: Equatable, Sendable {
    case finishingAudio(UUID)
    case transcribing(UUID)

    public var recordingID: UUID {
        switch self {
        case .finishingAudio(let id), .transcribing(let id): id
        }
    }
}

@MainActor
public final class RecordingJobQueue {
    typealias FinalizeOperation = @Sendable (
        RecordingManifest,
        RecordingStore
    ) async throws -> RecordingPostProcessingResult
    typealias TranscribeOperation = @Sendable (
        RecordingManifest,
        RecordingStore,
        String
    ) async throws -> RecordingManifest

    public var onChange: (@MainActor (RecordingJobActivity?) -> Void)?

    public private(set) var activity: RecordingJobActivity? {
        didSet { onChange?(activity) }
    }

    private let store: RecordingStore
    private let apiKeyProvider: @Sendable () throws -> String?
    private let finalizeOperation: FinalizeOperation
    private let transcribeOperation: TranscribeOperation
    private var captureBlocksNewWork = true
    private var runnerTask: Task<Void, Never>?
    private var transcriptionTask: Task<RecordingManifest, Error>?

    public convenience init(
        store: RecordingStore,
        postProcessor: RecordingPostProcessor = RecordingPostProcessor(),
        transcriptionService: TranscriptionService = TranscriptionService(),
        apiKeyProvider: @escaping @Sendable () throws -> String?
    ) {
        self.init(
            store: store,
            apiKeyProvider: apiKeyProvider,
            finalize: { recording, store in
                try await Task.detached(priority: .utility) {
                    try postProcessor.process(recording: recording, store: store)
                }.value
            },
            transcribe: { recording, store, apiKey in
                try await transcriptionService.transcribe(
                    recording: recording,
                    store: store,
                    apiKey: apiKey
                )
            }
        )
    }

    init(
        store: RecordingStore,
        apiKeyProvider: @escaping @Sendable () throws -> String?,
        finalize: @escaping FinalizeOperation,
        transcribe: @escaping TranscribeOperation
    ) {
        self.store = store
        self.apiKeyProvider = apiKeyProvider
        finalizeOperation = finalize
        transcribeOperation = transcribe
    }

    public func start() {
        captureBlocksNewWork = false
        wake()
    }

    public func suspendNewWork() {
        captureBlocksNewWork = true
    }

    public func captureDidEnd() {
        captureBlocksNewWork = false
        wake()
    }

    public func wake() {
        guard !captureBlocksNewWork, runnerTask == nil else { return }
        runnerTask = Task { [weak self] in
            await self?.run()
        }
    }

    public func shutdownImmediately() {
        captureBlocksNewWork = true
        transcriptionTask?.cancel()
        runnerTask?.cancel()
    }

    public func isWorking(on recordingID: UUID) -> Bool {
        activity?.recordingID == recordingID
    }

    private func run() async {
        var attempted: Set<WorkKey> = []
        defer {
            runnerTask = nil
            activity = nil
        }

        while !captureBlocksNewWork, !Task.isCancelled {
            let recordings: [RecordingManifest]
            do {
                recordings = try store.loadAll()
            } catch {
                return
            }
            guard let work = Self.nextWork(in: recordings, excluding: attempted) else { return }
            attempted.insert(work.key)

            switch work {
            case .finalize(let recording):
                await finalize(recording)
            case .transcribe(let recording):
                await transcribe(recording)
            }
        }
    }

    private func finalize(_ original: RecordingManifest) async {
        activity = .finishingAudio(original.id)
        let interruptionMessage = original.lastFailure?.stage == .finalization
            ? original.lastFailure?.message
            : nil

        do {
            let result = try await finalizeOperation(original, store)
            var recording = try store.load(id: original.id)
            recording.files.exportDirectory = result.publication.directoryURL.path
            recording.files.audio = result.publication.audioURL.path
            recording.files.audioBookmark = try? store.bookmark(for: result.publication.audioURL)
            recording.files.transcriptMarkdown = result.publication.directoryURL
                .appendingPathComponent("Transcript.md").path
            recording.durationSeconds = result.publication.durationSeconds
            if recording.captureEndedAt == nil {
                recording.captureEndedAt = recording.effectiveStartedAt.addingTimeInterval(
                    result.publication.durationSeconds
                )
                recording.stoppedAt = recording.captureEndedAt
            }
            if recording.lastFailure?.stage == .capture {
                recording.captureStatus = .failed
            } else {
                recording.captureStatus = .complete
                recording.lastFailure = nil
            }
            recording.warnings.append(contentsOf: result.warnings)
            if let interruptionMessage {
                recording.warnings.append("Recovered after interruption: \(interruptionMessage)")
            }
            try store.save(recording)
            do {
                try store.removeCaptureArtifacts(for: recording)
            } catch {
                recording.warnings.append(
                    "Temporary recovery files could not be removed: \(error.localizedDescription)"
                )
                try store.save(recording)
            }
            onChange?(activity)
        } catch {
            guard var recording = try? store.load(id: original.id) else { return }
            recording.captureStatus = .failed
            if recording.lastFailure?.stage == .capture {
                let warning = "Audio finalization failed: \(error.localizedDescription)"
                if !recording.warnings.contains(warning) {
                    recording.warnings.append(warning)
                }
            } else {
                recording.lastFailure = RecordingFailure(
                    stage: .finalization,
                    message: error.localizedDescription
                )
            }
            try? store.save(recording)
            onChange?(activity)
        }
    }

    private func transcribe(_ original: RecordingManifest) async {
        guard !captureBlocksNewWork else { return }
        let apiKey: String
        if store.expectsRetainedTranscriptResponse(for: original) {
            apiKey = ""
        } else {
            do {
                guard let resolved = try apiKeyProvider(), !resolved.isEmpty else {
                    var recording = try store.load(id: original.id)
                    recording.transcriptionStatus = .waitingForCredential
                    if recording.lastFailure?.stage == .transcription {
                        recording.lastFailure = nil
                    }
                    try store.save(recording)
                    onChange?(activity)
                    return
                }
                apiKey = resolved
            } catch {
                guard var recording = try? store.load(id: original.id) else { return }
                recording.transcriptionStatus = .failed
                recording.lastFailure = RecordingFailure(
                    stage: .transcription,
                    message: error.localizedDescription
                )
                try? store.save(recording)
                onChange?(activity)
                return
            }
        }

        guard !captureBlocksNewWork else { return }
        activity = .transcribing(original.id)
        let task = Task.detached(priority: .utility) { [transcribeOperation, store] in
            try await transcribeOperation(original, store, apiKey)
        }
        transcriptionTask = task
        let result = await task.result
        transcriptionTask = nil
        if case .failure(let error) = result,
           !Task.isCancelled {
            persistTranscriptionFailureIfNeeded(for: original.id, error: error)
        }
        onChange?(activity)
    }

    private func persistTranscriptionFailureIfNeeded(for id: UUID, error: Error) {
        guard var recording = try? store.load(id: id),
              recording.transcriptionStatus == .notStarted ||
                recording.transcriptionStatus == .transcribing
        else { return }
        recording.transcriptionStatus = .failed
        recording.lastFailure = RecordingFailure(
            stage: .transcription,
            message: error.localizedDescription
        )
        try? store.save(recording)
    }

    private enum Work {
        case finalize(RecordingManifest)
        case transcribe(RecordingManifest)

        var key: WorkKey {
            switch self {
            case .finalize(let recording): .finalize(recording.id)
            case .transcribe(let recording): .transcribe(recording.id)
            }
        }
    }

    private enum WorkKey: Hashable {
        case finalize(UUID)
        case transcribe(UUID)
    }

    private static func nextWork(
        in recordings: [RecordingManifest],
        excluding attempted: Set<WorkKey>
    ) -> Work? {
        for recording in recordings.sorted(by: { $0.createdAt < $1.createdAt }) {
            if recording.captureStatus == .processing,
               !attempted.contains(.finalize(recording.id)) {
                return .finalize(recording)
            }
            if recording.captureStatus == .complete,
               recording.transcriptionStatus == .notStarted,
               !attempted.contains(.transcribe(recording.id)) {
                return .transcribe(recording)
            }
        }
        return nil
    }
}
