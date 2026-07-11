import Foundation
@testable import CallRecorderCore

func runDeepgramAndTranscriptTests() throws {
    try runTest("prerecorded request uses current required options") {
        let request = try DeepgramRequestFactory.makeRequest(
            language: .hebrew,
            apiKey: "test-only-secret"
        )
        let url = try require(request.url)
        let components = try require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        try expectEqual(request.httpMethod, "POST")
        try expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        try expectEqual(query["model"], "nova-3")
        try expectEqual(query["language"], "he")
        try expectEqual(query["smart_format"], "true")
        try expectEqual(query["paragraphs"], "true")
        try expectEqual(query["utterances"], "true")
        try expectEqual(query["utt_split"], "1.0")
        try expectEqual(query["multichannel"], "true")
        try expectEqual(query["diarize_model"], "latest")
        try expectEqual(query["mip_opt_out"], "true")
        try expectEqual(query["tag"], "call-recorder")
        try expect(query["diarize"] == nil)
    }

    try runTest("Nova-3 keyterms are normalized and sent as separate parameters") {
        let parsed = DeepgramKeyterms.parse(" YeshID\nDecision Trace\nYeshID\n\n")
        try expectEqual(parsed, ["YeshID", "Decision Trace"])
        let request = try DeepgramRequestFactory.makeRequest(
            language: .english,
            apiKey: "test-only-secret",
            keyterms: parsed
        )
        let url = try require(request.url)
        let components = try require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let keyterms = (components.queryItems ?? [])
            .filter { $0.name == "keyterm" }
            .compactMap(\.value)
        try expectEqual(keyterms, ["YeshID", "Decision Trace"])

        let limited = DeepgramKeyterms.limited(
            (0...DeepgramKeyterms.maximumCount).map { "Term \($0)" }
        )
        try expectEqual(limited.count, DeepgramKeyterms.maximumCount)
        try expectEqual(limited.last, "Term 99")
    }

    try runTest("M4A uploads use the MPEG-4 audio content type") {
        let audioURL = URL(fileURLWithPath: "/tmp/Audio.m4a")
        try expectEqual(
            DeepgramRequestFactory.contentType(for: audioURL),
            "audio/mp4"
        )
        let request = try DeepgramRequestFactory.makeRequest(
            language: .english,
            apiKey: "test-only-secret",
            contentType: DeepgramRequestFactory.contentType(for: audioURL)
        )
        try expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
    }

    try runTest("utterances merge by timestamp and use the configured local speaker name") {
        let response = Data(
            """
            {
              "results": {
                "channels": [
                  {"alternatives": [{"transcript": "Remote", "words": []}]},
                  {"alternatives": [{"transcript": "Local", "words": []}]}
                ],
                "utterances": [
                  {
                    "start": 2.0, "end": 2.5, "channel": [1], "speaker": 0,
                    "confidence": 0.99, "transcript": "I agree.",
                    "words": [{
                      "word": "agree", "start": 2.0, "end": 2.5,
                      "confidence": 0.99, "speaker": 0, "speaker_confidence": 0.99
                    }]
                  },
                  {
                    "start": 0.5, "end": 1.0, "channel": 0, "speaker": 3,
                    "confidence": 0.95, "transcript": "Welcome.",
                    "words": [{
                      "word": "Welcome", "start": 0.5, "end": 1.0,
                      "confidence": 0.95, "speaker": 3, "speaker_confidence": 0.95
                    }]
                  }
                ]
              }
            }
            """.utf8
        )
        let document = try TranscriptDocument(deepgramResponse: response)
        try expectEqual(document.segments.map(\.channel), [0, 1])
        try expectEqual(document.segments.map(\.speaker), [3, 0])
        try expectEqual(document.segments.map(\.text), ["Welcome.", "I agree."])
        try expectEqual(document.segments.map(\.transcriptionConfidence), [0.95, 0.99])
        try expectEqual(document.segments.map(\.speakerConfidence), [0.95, 0.99])

        var recording = RecordingManifest(
            createdAt: Date(timeIntervalSince1970: 1_000),
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic",
            localSpeakerName: "  Taylor\nRivera  "
        )
        recording.captureStatus = .complete
        recording.captureStartedAt = Date(timeIntervalSince1970: 1_100.125)
        recording.captureEndedAt = Date(timeIntervalSince1970: 1_102.625)
        recording.timeZoneIdentifier = "Asia/Jerusalem"
        recording.durationSeconds = 2.5
        recording.files.audio = "/tmp/Audio.m4a"
        let markdown = TranscriptMarkdownFormatter.format(document: document, recording: recording)
        try expect(markdown.contains("started_at: \"1970-01-01T00:18:20.125Z\""))
        try expect(markdown.contains("ended_at: \"1970-01-01T00:18:22.625Z\""))
        try expect(markdown.contains("timezone: \"Asia/Jerusalem\""))
        try expect(markdown.contains("duration_seconds: 2.500"))
        try expect(markdown.contains("timestamp_source: \"capture_clock\""))
        try expect(markdown.contains("audio_file: \"Audio.m4a\""))
        try expect(markdown.contains("calendar_match_status: unmatched"))
        try expect(markdown.contains("[00:00:00.500] **Speaker 3:** Welcome."))
        try expect(markdown.contains("[00:00:02.000] **Taylor Rivera:** I agree."))
        try expect(markdown.contains("Channel 1: Taylor Rivera"))
        try expect(!markdown.contains("_[review]_"))

        recording.origin = .importedAudio
        recording.timestampSource = .fileCreationDate
        let importedMarkdown = TranscriptMarkdownFormatter.format(
            document: document,
            recording: recording
        )
        try expect(importedMarkdown.contains("timestamp_source: \"file_creation_date\""))
        try expect(importedMarkdown.contains("Source: Imported audio"))
        try expect(
            importedMarkdown.contains(
                "[00:00:02.000] **Channel 1 · Speaker 0:** I agree."
            )
        )
    }

    try runTest("paragraphs group utterances across channels and retain review confidence") {
        let response = Data(
            """
            {
              "results": {
                "channels": [
                  {
                    "alternatives": [{
                      "transcript": "Welcome back.",
                      "words": [
                        {
                          "word": "Welcome", "start": 0.5, "end": 0.9,
                          "confidence": 0.95, "speaker": 3,
                          "speaker_confidence": 0.90
                        },
                        {
                          "word": "back", "start": 1.2, "end": 1.5,
                          "confidence": 0.85, "speaker": 3,
                          "speaker_confidence": 0.80
                        }
                      ],
                      "paragraphs": {
                        "paragraphs": [{
                          "sentences": [{"text": "Welcome back."}],
                          "speaker": 3, "start": 0.5, "end": 1.5
                        }]
                      }
                    }]
                  },
                  {
                    "alternatives": [{
                      "transcript": "I agree.",
                      "words": [{
                        "word": "agree", "start": 2.0, "end": 2.5,
                        "confidence": 0.99, "speaker": 0,
                        "speaker_confidence": 0.99
                      }],
                      "paragraphs": {
                        "paragraphs": [{
                          "sentences": [{"text": "I agree."}],
                          "speaker": 0, "start": 2.0, "end": 2.5
                        }]
                      }
                    }]
                  }
                ],
                "utterances": [
                  {
                    "start": 0.5, "end": 0.9, "channel": 0, "speaker": 3,
                    "confidence": 0.95, "transcript": "Welcome",
                    "words": [{"word": "Welcome", "start": 0.5, "end": 0.9,
                      "confidence": 0.95, "speaker": 3, "speaker_confidence": 0.90}]
                  },
                  {
                    "start": 1.2, "end": 1.5, "channel": 0, "speaker": 3,
                    "confidence": 0.70, "transcript": "back.",
                    "words": [{"word": "back", "start": 1.2, "end": 1.5,
                      "confidence": 0.85, "speaker": 3, "speaker_confidence": 0.80}]
                  },
                  {
                    "start": 2.0, "end": 2.5, "channel": 1, "speaker": 0,
                    "confidence": 0.99, "transcript": "I agree.",
                    "words": [{"word": "agree", "start": 2.0, "end": 2.5,
                      "confidence": 0.99, "speaker": 0, "speaker_confidence": 0.99}]
                  }
                ]
              }
            }
            """.utf8
        )

        let document = try TranscriptDocument(deepgramResponse: response)
        try expectEqual(document.segments.map(\.text), ["Welcome back.", "I agree."])
        try expectEqual(document.segments.map(\.channel), [0, 1])
        try expectEqual(document.segments.map(\.speaker), [3, 0])
        try expectEqual(document.segments.map(\.transcriptionConfidence), [0.70, 0.99])
        try expectEqual(document.segments.map(\.speakerConfidence), [0.80, 0.99])

        var recording = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic",
            localSpeakerName: "Taylor"
        )
        recording.captureStatus = .complete
        let markdown = TranscriptMarkdownFormatter.format(
            document: document,
            recording: recording
        )
        try expect(markdown.contains("**Speaker 3:** Welcome back. _[review]_"))
        try expect(markdown.contains("**Taylor:** I agree."))
    }

    try runTest("incomplete paragraph data falls back to complete utterances") {
        let response = Data(
            """
            {
              "results": {
                "channels": [
                  {"alternatives": [{
                    "transcript": "Remote words.",
                    "words": [{"word": "Remote", "start": 0.0, "end": 0.5}],
                    "paragraphs": {"paragraphs": [{
                      "sentences": [{"text": "Remote paragraph."}],
                      "speaker": 1, "start": 0.0, "end": 0.5
                    }]}
                  }]},
                  {"alternatives": [{
                    "transcript": "Local words.",
                    "words": [{"word": "Local", "start": 0.6, "end": 1.0}]
                  }]}
                ],
                "utterances": [
                  {"start": 0.0, "end": 0.5, "channel": 0, "speaker": 1,
                    "transcript": "Remote utterance."},
                  {"start": 0.6, "end": 1.0, "channel": 1, "speaker": 0,
                    "transcript": "Local utterance."}
                ]
              }
            }
            """.utf8
        )

        let document = try TranscriptDocument(deepgramResponse: response)
        try expectEqual(
            document.segments.map(\.text),
            ["Remote utterance.", "Local utterance."]
        )
    }

    try runTest("low transcription or remote-speaker confidence marks only uncertain passages") {
        let document = TranscriptDocument(
            segments: [
                TranscriptSegment(
                    start: 1,
                    end: 2,
                    channel: 0,
                    speaker: 2,
                    text: "Remote words.",
                    transcriptionConfidence: 0.95,
                    speakerConfidence: 0.60
                ),
                TranscriptSegment(
                    start: 3,
                    end: 4,
                    channel: 1,
                    speaker: 0,
                    text: "Local words.",
                    transcriptionConfidence: 0.60,
                    speakerConfidence: 0.95
                ),
            ]
        )
        var recording = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic"
        )
        recording.captureStatus = .complete

        let markdown = TranscriptMarkdownFormatter.format(
            document: document,
            recording: recording
        )
        try expect(markdown.contains("Review: 2 passages are marked"))
        try expect(markdown.contains("**Speaker 2:** Remote words. _[review]_"))
        try expect(markdown.contains("**Me:** Local words. _[review]_"))
    }

    try runTest("only retained finalized audio is retryable") {
        var recording = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic"
        )
        recording.captureStatus = .complete
        recording.transcriptionStatus = .failed
        try expect(!TranscriptionRetryPolicy.canRetry(recording))
        recording.files.audio = "audio.wav"
        try expect(TranscriptionRetryPolicy.canRetry(recording))
        recording.transcriptionStatus = .complete
        try expect(!TranscriptionRetryPolicy.canRetry(recording))
    }
}
