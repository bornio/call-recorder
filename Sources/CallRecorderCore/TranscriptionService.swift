import Foundation

public struct TranscriptionService: Sendable {
    private let client: DeepgramClient

    public init(client: DeepgramClient = DeepgramClient()) {
        self.client = client
    }

    public func transcribe(
        recording original: RecordingManifest,
        store: RecordingStore,
        apiKey: String,
        now: Date = Date()
    ) async throws -> RecordingManifest {
        var recording = original
        guard recording.captureStatus == .complete,
              let audioURL = try store.audioURL(for: recording)
        else {
            throw DeepgramError.unreadableAudio
        }

        recording.transcriptionStatus = .transcribing
        recording.transcriptionAttempts += 1
        recording.lastFailure = nil
        try store.save(recording)

        do {
            let response = try await client.transcribe(
                audioURL: audioURL,
                language: recording.language,
                apiKey: apiKey,
                keyterms: recording.effectiveKeyterms
            )
            let document = try TranscriptDocument(deepgramResponse: response)
            let markdown = TranscriptMarkdownFormatter.format(
                document: document,
                recording: recording
            )
            let directory = try store.directory(for: recording)
            let jsonURL = directory.appendingPathComponent("transcript.json")
            var markdownURL: URL
            if let existingTranscript = recording.files.transcriptMarkdown {
                markdownURL = try store.fileURL(for: existingTranscript, in: recording)
            } else if recording.effectiveOrigin == .importedAudio {
                let basename = audioURL.deletingPathExtension().lastPathComponent
                let filename = basename == "Audio" ? "Transcript.md" : "\(basename).md"
                markdownURL = audioURL.deletingLastPathComponent().appendingPathComponent(filename)
            } else if let exportDirectory = recording.files.exportDirectory {
                markdownURL = URL(fileURLWithPath: exportDirectory)
                    .appendingPathComponent("Transcript.md")
            } else {
                markdownURL = directory.appendingPathComponent("Transcript.md")
            }
            if recording.effectiveOrigin == .importedAudio,
               FileManager.default.fileExists(atPath: markdownURL.path) {
                markdownURL = store.availableTranscriptURL(
                    beside: audioURL,
                    origin: .importedAudio
                )
                recording.files.transcriptMarkdown = markdownURL.path
                recording.files.transcriptBookmark = nil
                try store.save(recording)
            }
            try response.write(to: jsonURL, options: [.atomic])
            let markdownData = Data(markdown.utf8)
            while true {
                do {
                    try AtomicFilePublisher.publishNewFile(markdownData, to: markdownURL)
                    break
                } catch AtomicFilePublisherError.destinationExists
                    where recording.effectiveOrigin == .importedAudio {
                    markdownURL = store.availableTranscriptURL(
                        beside: audioURL,
                        origin: .importedAudio
                    )
                    recording.files.transcriptMarkdown = markdownURL.path
                    recording.files.transcriptBookmark = nil
                    try store.save(recording)
                }
            }
            try? FileManager.default.setAttributes(
                [
                    .creationDate: recording.effectiveStartedAt,
                    .modificationDate: now,
                ],
                ofItemAtPath: markdownURL.path
            )

            recording.files.transcriptJSON = "transcript.json"
            recording.files.transcriptMarkdown = markdownURL.path
            recording.files.transcriptBookmark = try? store.bookmark(for: markdownURL)
            recording.transcriptionStatus = .complete
            recording.lastFailure = nil
            try store.save(recording)
            return recording
        } catch {
            let transcriptionError = error
            recording.transcriptionStatus = .failed
            recording.lastFailure = RecordingFailure(
                stage: .transcription,
                message: transcriptionError.localizedDescription,
                occurredAt: now
            )
            do {
                try store.save(recording)
            } catch {
                throw TranscriptionServiceError.persistenceAfterFailure(
                    transcription: transcriptionError.localizedDescription,
                    persistence: error.localizedDescription
                )
            }
            throw transcriptionError
        }
    }
}

public enum TranscriptionServiceError: LocalizedError, Sendable {
    case persistenceAfterFailure(transcription: String, persistence: String)

    public var errorDescription: String? {
        switch self {
        case .persistenceAfterFailure(let transcription, let persistence):
            "\(transcription) The failed status could not be saved: \(persistence)"
        }
    }
}
