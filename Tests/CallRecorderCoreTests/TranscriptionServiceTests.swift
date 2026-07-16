import Foundation
@testable import CallRecorderCore

func runTranscriptionServiceTests() async throws {
    try await runAsyncTest("transcription publishes only Markdown beside retained audio") {
        try await withTranscriptionTemporaryDirectory { root in
            let response = Data(
                """
                {
                  "results": {
                    "channels": [
                      {"alternatives": [{"transcript": "Hello", "words": []}]},
                      {"alternatives": [{"transcript": "Hi", "words": []}]}
                    ],
                    "utterances": [
                      {"start": 0.0, "end": 0.5, "channel": 0, "speaker": 1, "transcript": "Hello"},
                      {"start": 0.6, "end": 1.0, "channel": 1, "speaker": 0, "transcript": "Hi"}
                    ]
                  }
                }
                """.utf8
            )
            let client = DeepgramClient { request, _ in
                guard request.value(forHTTPHeaderField: "Content-Type") == "audio/mp4",
                      request.value(forHTTPHeaderField: "Authorization") == "Token test-key",
                      let url = request.url,
                      URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.filter({ $0.name == "keyterm" })
                        .compactMap(\.value) == ["YeshID", "Decision Trace"],
                      let httpResponse = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                      )
                else {
                    throw TestFailure(description: "Unexpected upload request")
                }
                return (response, httpResponse)
            }
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic",
                localSpeakerName: "Taylor",
                keyterms: ["YeshID", "Decision Trace"],
                now: Date(timeIntervalSince1970: 1_720_600_200)
            )
            let publicDirectory = root.appendingPathComponent("2024-07-10 11-30 — Call")
            try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
            let audioURL = publicDirectory.appendingPathComponent("Audio.m4a")
            try Data([0, 1, 2, 3]).write(to: audioURL)
            recording.captureStatus = .complete
            recording.captureStartedAt = Date(timeIntervalSince1970: 1_720_600_200)
            recording.captureEndedAt = Date(timeIntervalSince1970: 1_720_600_201)
            recording.timeZoneIdentifier = "Asia/Jerusalem"
            recording.durationSeconds = 1
            recording.files.exportDirectory = publicDirectory.path
            recording.files.audio = audioURL.path
            recording.files.audioBookmark = try store.bookmark(for: audioURL)
            recording.files.transcriptMarkdown = publicDirectory
                .appendingPathComponent("Transcript.md").path
            try store.save(recording)
            try store.removeCaptureArtifacts(for: recording)

            let completed = try await TranscriptionService(client: client).transcribe(
                recording: recording,
                store: store,
                apiKey: "test-key",
                now: Date(timeIntervalSince1970: 1_720_600_205)
            )

            try expectEqual(completed.transcriptionStatus, .complete)
            let publicFiles = try FileManager.default.contentsOfDirectory(
                at: publicDirectory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted()
            try expectEqual(publicFiles, ["Audio.m4a", "Transcript.md"])
            let privateFiles = try FileManager.default.contentsOfDirectory(
                at: store.directory(for: completed),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted()
            try expectEqual(privateFiles, ["manifest.json", "transcript.json"])
            let markdownURL = try require(try store.transcriptURL(for: completed))
            let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
            try expect(markdown.contains("started_at: \"2024-07-10T08:30:00.000Z\""))
            try expect(markdown.contains("[00:00:00.600] **Taylor:** Hi"))
        }
    }

    try await runAsyncTest("failed transcription preserves audio and remains retryable") {
        try await withTranscriptionTemporaryDirectory { root in
            let client = DeepgramClient { _, _ in
                throw URLError(.notConnectedToInternet)
            }
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let publicDirectory = root.appendingPathComponent("Call")
            try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
            let audioURL = publicDirectory.appendingPathComponent("Audio.m4a")
            try Data([0, 1, 2, 3]).write(to: audioURL)
            recording.captureStatus = .complete
            recording.files.exportDirectory = publicDirectory.path
            recording.files.audio = audioURL.path
            recording.files.audioBookmark = try store.bookmark(for: audioURL)
            recording.files.transcriptMarkdown = publicDirectory
                .appendingPathComponent("Transcript.md").path
            try store.save(recording)

            do {
                _ = try await TranscriptionService(client: client).transcribe(
                    recording: recording,
                    store: store,
                    apiKey: "test-key"
                )
                throw TestFailure(description: "Expected transcription to fail")
            } catch is TestFailure {
                throw TestFailure(description: "Expected transcription to fail")
            } catch {
                let failed = try require(try store.loadAll().first)
                try expectEqual(failed.transcriptionStatus, .failed)
                try expect(TranscriptionRetryPolicy.canRetry(failed))
                try expect(FileManager.default.fileExists(atPath: audioURL.path))
                try expect(
                    !FileManager.default.fileExists(
                        atPath: publicDirectory.appendingPathComponent("Transcript.md").path
                    )
                )
            }
        }
    }

    try await runAsyncTest("successful Deepgram JSON is retained before app-side parsing") {
        try await withTranscriptionTemporaryDirectory { root in
            let response = Data("{\"unexpected\":true}".utf8)
            let client = DeepgramClient { request, _ in
                let url = try require(request.url)
                let httpResponse = try require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                ))
                return (response, httpResponse)
            }
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let publicDirectory = root.appendingPathComponent("Call", isDirectory: true)
            try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
            let audioURL = publicDirectory.appendingPathComponent("Audio.m4a")
            try Data([0, 1, 2, 3]).write(to: audioURL)
            recording.captureStatus = .complete
            recording.files.audio = audioURL.path
            recording.files.transcriptMarkdown = publicDirectory
                .appendingPathComponent("Transcript.md").path
            try store.save(recording)

            do {
                _ = try await TranscriptionService(client: client).transcribe(
                    recording: recording,
                    store: store,
                    apiKey: "test-key"
                )
                throw TestFailure(description: "Expected local parsing to fail")
            } catch is TestFailure {
                throw TestFailure(description: "Expected local parsing to fail")
            } catch {}

            let retained = try store.load(id: recording.id)
            try expectEqual(retained.transcriptionStatus, .failed)
            try expectEqual(retained.transcriptionAttempts, 1)
            try expectEqual(retained.files.transcriptJSON, "transcript.json")
            try expectEqual(try store.retainedTranscriptData(for: retained), response)

            let noUploadClient = DeepgramClient { _, _ in
                throw TestFailure(description: "Retained JSON must not upload again")
            }
            do {
                _ = try await TranscriptionService(client: noUploadClient).transcribe(
                    recording: retained,
                    store: store,
                    apiKey: ""
                )
                throw TestFailure(description: "Expected retained JSON parsing to fail")
            } catch let failure as TestFailure {
                throw failure
            } catch {}
            try expectEqual(try store.load(id: recording.id).transcriptionAttempts, 1)
        }
    }

    try await runAsyncTest("cancelled transcription requires an explicit retry") {
        try await withTranscriptionTemporaryDirectory { root in
            let client = DeepgramClient { _, _ in
                throw URLError(.cancelled)
            }
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let publicDirectory = root.appendingPathComponent("Call")
            try FileManager.default.createDirectory(
                at: publicDirectory,
                withIntermediateDirectories: true
            )
            let audioURL = publicDirectory.appendingPathComponent("Audio.m4a")
            try Data([0, 1, 2, 3]).write(to: audioURL)
            recording.captureStatus = .complete
            recording.files.exportDirectory = publicDirectory.path
            recording.files.audio = audioURL.path
            recording.files.audioBookmark = try store.bookmark(for: audioURL)
            recording.files.transcriptMarkdown = publicDirectory
                .appendingPathComponent("Transcript.md").path
            try store.save(recording)

            do {
                _ = try await TranscriptionService(client: client).transcribe(
                    recording: recording,
                    store: store,
                    apiKey: "test-key"
                )
                throw TestFailure(description: "Expected transcription cancellation")
            } catch is CancellationError {
                let queued = try require(try store.loadAll().first)
                try expectEqual(queued.transcriptionStatus, .failed)
                try expectEqual(queued.lastFailure?.stage, .transcription)
                try expect(queued.lastFailure?.message.contains("may already") == true)
                try expect(FileManager.default.fileExists(atPath: audioURL.path))
            }
        }
    }

    try await runAsyncTest("saved Deepgram response recreates Markdown without key or upload") {
        try await withTranscriptionTemporaryDirectory { root in
            let response = Data(
                "{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"Recovered\",\"words\":[]}]}]}}".utf8
            )
            let client = DeepgramClient { _, _ in
                throw TestFailure(description: "Saved response must not upload")
            }
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let publicDirectory = root.appendingPathComponent("Call", isDirectory: true)
            try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
            let audioURL = publicDirectory.appendingPathComponent("Audio.m4a")
            let existingMarkdown = publicDirectory.appendingPathComponent("Transcript.md")
            try Data([0, 1, 2, 3]).write(to: audioURL)
            try Data("keep me".utf8).write(to: existingMarkdown)
            recording.captureStatus = .complete
            recording.transcriptionStatus = .failed
            recording.transcriptionAttempts = 3
            recording.files.audio = audioURL.path
            recording.files.transcriptMarkdown = existingMarkdown.path
            try store.save(recording)
            try response.write(
                to: try store.directory(for: recording).appendingPathComponent("transcript.json")
            )

            let completed = try await TranscriptionService(client: client).transcribe(
                recording: recording,
                store: store,
                apiKey: ""
            )

            try expectEqual(completed.transcriptionStatus, .complete)
            try expectEqual(completed.transcriptionAttempts, 3)
            try expectEqual(
                try String(contentsOf: existingMarkdown, encoding: .utf8),
                "keep me"
            )
            let regenerated = try require(try store.transcriptURL(for: completed))
            try expectEqual(regenerated.lastPathComponent, "Transcript (2).md")
            let regeneratedMarkdown = try String(contentsOf: regenerated, encoding: .utf8)
            try expect(regeneratedMarkdown.contains("Recovered"))
        }
    }

    try await runAsyncTest("imported transcription does not overwrite an existing Markdown file") {
        try await withTranscriptionTemporaryDirectory { root in
            let response = Data(
                """
                {"results":{"channels":[{"alternatives":[{"transcript":"Hello","words":[]}]}]}}
                """.utf8
            )
            let client = DeepgramClient { request, _ in
                let url = try require(request.url)
                let httpResponse = try require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    )
                )
                return (response, httpResponse)
            }
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            let audioURL = root.appendingPathComponent("meeting.m4a")
            let existingTranscript = root.appendingPathComponent("meeting.md")
            try Data([0, 1, 2, 3]).write(to: audioURL)
            try Data("keep me".utf8).write(to: existingTranscript)

            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "",
                microphoneName: "Imported audio"
            )
            recording.origin = .importedAudio
            recording.captureStatus = .complete
            recording.files.audio = audioURL.path
            recording.files.audioBookmark = try store.bookmark(for: audioURL)
            recording.files.transcriptMarkdown = existingTranscript.path
            try store.save(recording)

            let completed = try await TranscriptionService(client: client).transcribe(
                recording: recording,
                store: store,
                apiKey: "test-key"
            )

            try expectEqual(
                try String(contentsOf: existingTranscript, encoding: .utf8),
                "keep me"
            )
            let published = try require(try store.transcriptURL(for: completed))
            try expectEqual(published.lastPathComponent, "meeting (2).md")
            try expect(FileManager.default.fileExists(atPath: published.path))
        }
    }
}

private func withTranscriptionTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CallRecorderTranscriptionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try await body(url)
}
