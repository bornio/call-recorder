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

        let useRetainedResponse = store.expectsRetainedTranscriptResponse(for: recording)
        recording.transcriptionStatus = .transcribing
        if !useRetainedResponse {
            recording.transcriptionAttempts += 1
        }
        recording.lastFailure = nil
        try store.save(recording)

        do {
            let response: Data
            if useRetainedResponse {
                guard let retained = try store.retainedTranscriptData(for: recording) else {
                    throw TranscriptionServiceError.missingRetainedResponse
                }
                response = retained
            } else {
                guard !apiKey.isEmpty else {
                    throw TranscriptionServiceError.missingCredential
                }
                response = try await client.transcribe(
                    audioURL: audioURL,
                    language: recording.language,
                    apiKey: apiKey,
                    keyterms: recording.effectiveKeyterms
                )
            }
            let directory = try store.directory(for: recording)
            let jsonURL = directory.appendingPathComponent("transcript.json")
            if !useRetainedResponse {
                try response.write(to: jsonURL, options: [.atomic])
            }
            recording.files.transcriptJSON = "transcript.json"
            try store.save(recording)
            let document = try TranscriptDocument(deepgramResponse: response)

            let markdown = TranscriptMarkdownFormatter.format(
                document: document,
                recording: recording
            )
            var markdownURL = try preferredMarkdownURL(
                for: recording,
                audioURL: audioURL,
                privateDirectory: directory,
                store: store
            )
            markdownURL = store.availableURL(for: markdownURL)
            let markdownData = Data(markdown.utf8)
            while true {
                do {
                    try AtomicFilePublisher.publishNewFile(markdownData, to: markdownURL)
                    break
                } catch AtomicFilePublisherError.destinationExists {
                    markdownURL = store.availableURL(for: markdownURL)
                }
            }
            try? FileManager.default.setAttributes(
                [
                    .creationDate: recording.effectiveStartedAt,
                    .modificationDate: now,
                ],
                ofItemAtPath: markdownURL.path
            )

            recording.files.transcriptMarkdown = markdownURL.path
            recording.files.transcriptBookmark = try? store.bookmark(for: markdownURL)
            recording.transcriptionStatus = .complete
            recording.lastFailure = nil
            try store.save(recording)
            return recording
        } catch is CancellationError {
            recording.transcriptionStatus = .failed
            recording.lastFailure = RecordingFailure(
                stage: .transcription,
                message: "Transcription was interrupted. Deepgram may already have processed the audio; retry manually if needed.",
                occurredAt: now
            )
            try store.save(recording)
            throw CancellationError()
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

    private func preferredMarkdownURL(
        for recording: RecordingManifest,
        audioURL: URL,
        privateDirectory: URL,
        store: RecordingStore
    ) throws -> URL {
        if let existingTranscript = recording.files.transcriptMarkdown {
            return try store.fileURL(for: existingTranscript, in: recording)
        }
        if recording.effectiveOrigin == .importedAudio {
            return store.transcriptURL(beside: audioURL, origin: .importedAudio)
        }
        if let exportDirectory = recording.files.exportDirectory {
            return URL(fileURLWithPath: exportDirectory)
                .appendingPathComponent("Transcript.md")
        }
        return privateDirectory.appendingPathComponent("Transcript.md")
    }
}

public enum TranscriptionServiceError: LocalizedError, Sendable {
    case missingCredential
    case missingRetainedResponse
    case persistenceAfterFailure(transcription: String, persistence: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            "Add a Deepgram API key before transcribing this recording."
        case .missingRetainedResponse:
            "The saved Deepgram response is missing or unreadable. Retry manually to upload the audio again."
        case .persistenceAfterFailure(let transcription, let persistence):
            "\(transcription) The failed status could not be saved: \(persistence)"
        }
    }
}
