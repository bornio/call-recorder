import Foundation

public struct RecordingPostProcessingResult: Sendable {
    public var publication: PublishedRecordingAudio
    public var warnings: [String]

    public init(publication: PublishedRecordingAudio, warnings: [String]) {
        self.publication = publication
        self.warnings = warnings
    }
}

public struct RecordingPostProcessor: Sendable {
    private let finalizer: RecordingFinalizer
    private let audioExportService: AudioExportService

    public init(
        finalizer: RecordingFinalizer = RecordingFinalizer(),
        audioExportService: AudioExportService = AudioExportService()
    ) {
        self.finalizer = finalizer
        self.audioExportService = audioExportService
    }

    public func process(
        recording: RecordingManifest,
        store: RecordingStore
    ) throws -> RecordingPostProcessingResult {
        guard let exportPath = recording.files.exportDirectory else {
            throw RecordingPostProcessorError.missingPublicationDestination
        }
        let destinationDirectory = URL(fileURLWithPath: exportPath, isDirectory: true)
        let publishedAudio = destinationDirectory.appendingPathComponent("Audio.m4a")
        if FileManager.default.fileExists(atPath: publishedAudio.path) {
            return RecordingPostProcessingResult(
                publication: try audioExportService.recoverPublication(
                    in: destinationDirectory,
                    recordingID: recording.id
                ),
                warnings: []
            )
        }

        let recordingDirectory = try store.directory(for: recording)
        let systemDirectory = try store.url(
            for: recording.files.systemCaptureDirectory,
            in: recording
        )
        let microphoneDirectory = try store.url(
            for: recording.files.microphoneCaptureDirectory,
            in: recording
        )
        let waveURL = recordingDirectory.appendingPathComponent("audio.wav")
        let finalization = try finalizer.finalize(
            recordingDirectory: recordingDirectory,
            systemCaptureDirectory: systemDirectory,
            microphoneCaptureDirectory: microphoneDirectory,
            outputURL: waveURL
        )
        let publication = try audioExportService.publish(
            waveURL: waveURL,
            recording: recording,
            exportRoot: destinationDirectory.deletingLastPathComponent(),
            destinationDirectory: destinationDirectory
        )
        return RecordingPostProcessingResult(
            publication: publication,
            warnings: finalization.warnings
        )
    }
}

public enum RecordingPostProcessorError: LocalizedError, Sendable {
    case missingPublicationDestination

    public var errorDescription: String? {
        switch self {
        case .missingPublicationDestination:
            "The recording publication destination was not saved."
        }
    }
}
