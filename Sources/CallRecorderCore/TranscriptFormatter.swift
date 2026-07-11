import Foundation

public struct TranscriptSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var channel: Int
    public var speaker: Int?
    public var text: String
    public var transcriptionConfidence: Double?
    public var speakerConfidence: Double?

    public init(
        start: Double,
        end: Double,
        channel: Int,
        speaker: Int?,
        text: String,
        transcriptionConfidence: Double? = nil,
        speakerConfidence: Double? = nil
    ) {
        self.start = start
        self.end = end
        self.channel = channel
        self.speaker = speaker
        self.text = text
        self.transcriptionConfidence = transcriptionConfidence
        self.speakerConfidence = speakerConfidence
    }
}

public struct TranscriptDocument: Equatable, Sendable {
    public var segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments.sorted {
            if $0.start == $1.start { return $0.channel < $1.channel }
            return $0.start < $1.start
        }
    }

    public init(deepgramResponse data: Data) throws {
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        let paragraphSegments = Self.paragraphSegments(from: response)
        let channelsWithSpeech = Set<Int>(
            response.results.channels.enumerated().compactMap { channel, value in
                guard let alternative = value.alternatives.first else { return nil }
                let hasTranscript = !alternative.transcript
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasWords = !(alternative.words ?? []).isEmpty
                return hasTranscript || hasWords ? channel : nil
            }
        )
        let channelsWithParagraphs = Set(paragraphSegments.map(\.channel))
        if !paragraphSegments.isEmpty,
           channelsWithSpeech.isSubset(of: channelsWithParagraphs) {
            segments = Self.sorted(paragraphSegments)
            return
        }

        if let utterances = response.results.utterances, !utterances.isEmpty {
            segments = utterances.compactMap { utterance in
                let text = utterance.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    start: utterance.start,
                    end: utterance.end,
                    channel: utterance.channel?.value ?? 0,
                    speaker: utterance.speaker ?? utterance.words?.first?.speaker,
                    text: text,
                    transcriptionConfidence: utterance.confidence
                        ?? Self.average(utterance.words?.map(\.confidence) ?? []),
                    speakerConfidence: Self.average(
                        utterance.words?.map(\.speakerConfidence) ?? []
                    )
                )
            }
            segments = Self.sorted(segments)
            return
        }

        var fallback: [TranscriptSegment] = []
        for (channelIndex, channel) in response.results.channels.enumerated() {
            guard let alternative = channel.alternatives.first else { continue }
            if let words = alternative.words, !words.isEmpty {
                fallback.append(contentsOf: Self.groupWords(words, channel: channelIndex))
            } else {
                let text = alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    fallback.append(
                        TranscriptSegment(
                            start: 0,
                            end: 0,
                            channel: channelIndex,
                            speaker: nil,
                            text: text,
                            transcriptionConfidence: alternative.confidence
                        )
                    )
                }
            }
        }
        segments = Self.sorted(fallback)
    }

    private static func paragraphSegments(from response: DeepgramResponse) -> [TranscriptSegment] {
        response.results.channels.enumerated().flatMap { channel, value -> [TranscriptSegment] in
            guard let alternative = value.alternatives.first else { return [] }
            let utterances = (response.results.utterances ?? []).filter {
                ($0.channel?.value ?? 0) == channel
            }
            return (alternative.paragraphs?.paragraphs ?? []).compactMap { paragraph in
                let text = paragraph.sentences
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }

                let words = (alternative.words ?? []).filter {
                    overlaps($0.start, $0.end, paragraph.start, paragraph.end)
                }
                let overlappingUtterances = utterances.filter {
                    overlaps($0.start, $0.end, paragraph.start, paragraph.end)
                }
                let transcriptionConfidence = minimum(
                    overlappingUtterances.map {
                        $0.confidence ?? average($0.words?.map(\.confidence) ?? [])
                    }
                ) ?? average(words.map(\.confidence))
                let speakerConfidence = minimum(
                    overlappingUtterances.map {
                        average($0.words?.map(\.speakerConfidence) ?? [])
                    }
                ) ?? average(words.map(\.speakerConfidence))

                return TranscriptSegment(
                    start: paragraph.start,
                    end: paragraph.end,
                    channel: channel,
                    speaker: paragraph.speaker ?? words.first?.speaker,
                    text: text,
                    transcriptionConfidence: transcriptionConfidence,
                    speakerConfidence: speakerConfidence
                )
            }
        }
    }

    private static func overlaps(
        _ firstStart: Double,
        _ firstEnd: Double,
        _ secondStart: Double,
        _ secondEnd: Double
    ) -> Bool {
        firstStart < secondEnd && firstEnd > secondStart
    }

    private static func minimum(_ values: [Double?]) -> Double? {
        values.compactMap { $0 }.min()
    }

    private static func sorted(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted {
            if $0.start == $1.start { return $0.channel < $1.channel }
            return $0.start < $1.start
        }
    }

    private static func groupWords(_ words: [DeepgramWord], channel: Int) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var currentWords: [DeepgramWord] = []
        var currentSpeaker: Int?

        func appendCurrent() {
            guard let first = currentWords.first, let last = currentWords.last else { return }
            let text = currentWords
                .map { $0.punctuatedWord ?? $0.word }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            result.append(
                TranscriptSegment(
                    start: first.start,
                    end: last.end,
                    channel: channel,
                    speaker: currentSpeaker,
                    text: text,
                    transcriptionConfidence: Self.average(currentWords.map(\.confidence)),
                    speakerConfidence: Self.average(currentWords.map(\.speakerConfidence))
                )
            )
        }

        for word in words {
            if !currentWords.isEmpty && word.speaker != currentSpeaker {
                appendCurrent()
                currentWords.removeAll(keepingCapacity: true)
            }
            currentSpeaker = word.speaker
            currentWords.append(word)
        }
        appendCurrent()
        return result
    }

    private static func average(_ values: [Double?]) -> Double? {
        let available = values.compactMap { $0 }
        guard !available.isEmpty else { return nil }
        return available.reduce(0, +) / Double(available.count)
    }
}

public enum TranscriptMarkdownFormatter {
    private static let reviewConfidenceThreshold = 0.75

    public static func format(
        document: TranscriptDocument,
        recording: RecordingManifest
    ) -> String {
        let startedAt = recording.effectiveStartedAt
        let endedAt = recording.effectiveEndedAt
        let timeZone = recording.timeZoneIdentifier ?? TimeZone.current.identifier
        let audioFilename = recording.files.audio.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? ""
        var lines = [
            "---",
            "recording_id: \(yaml(recording.id.uuidString))",
            "started_at: \(yaml(iso8601(startedAt)))",
            "ended_at: \(endedAt.map { yaml(iso8601($0)) } ?? "null")",
            "timezone: \(yaml(timeZone))",
            "duration_seconds: \(recording.durationSeconds.map { duration($0) } ?? "null")",
            "language: \(yaml(recording.language.rawValue))",
            "origin: \(yaml(recording.effectiveOrigin.rawValue))",
            "timestamp_source: \(yaml(recording.effectiveTimestampSource.rawValue))",
            "audio_file: \(yaml(audioFilename))",
            "calendar_match_status: unmatched",
            "calendar_event_id: null",
            "calendar_title: null",
            "---",
            "",
            "# Call transcript",
            "",
            "- Recorded: \(humanDate(startedAt, timeZoneIdentifier: timeZone)) (\(timeZone))",
            "- Language: \(recording.language.displayName)",
        ]
        if recording.effectiveOrigin == .nativeRecording {
            lines.append("- Channel 0: Remote/system audio")
            lines.append(
                "- Channel 1: \(markdownInline(recording.effectiveLocalSpeakerName)) (microphone)"
            )
        } else {
            lines.append("- Source: Imported audio")
        }
        let reviewCount = document.segments.filter {
            needsReview($0, recording: recording)
        }.count
        if reviewCount > 0 {
            let noun = reviewCount == 1 ? "passage is" : "passages are"
            lines.append(
                "- Review: \(reviewCount) \(noun) marked _[review]_ because "
                    + "wording or speaker attribution may be uncertain"
            )
        }
        lines.append("")
        lines.append("## Transcript")
        lines.append("")
        if document.segments.isEmpty {
            lines.append("_No speech was returned._")
        } else {
            for segment in document.segments {
                let reviewMarker = needsReview(segment, recording: recording)
                    ? " _[review]_"
                    : ""
                let speaker = label(for: segment, recording: recording)
                lines.append(
                    "[\(timestamp(segment.start))] **\(speaker):** "
                        + "\(segment.text)\(reviewMarker)"
                )
                lines.append("")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let wholeSeconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(
            format: "%02d:%02d:%02d.%03d",
            hours,
            minutes,
            wholeSeconds,
            remainder
        )
    }

    private static func label(
        for segment: TranscriptSegment,
        recording: RecordingManifest
    ) -> String {
        if recording.effectiveOrigin == .nativeRecording, segment.channel == 1 {
            return markdownInline(recording.effectiveLocalSpeakerName)
        }
        if recording.effectiveOrigin == .importedAudio, segment.channel > 0 {
            return "Channel \(segment.channel) · Speaker \(segment.speaker ?? 0)"
        }
        return "Speaker \(segment.speaker ?? 0)"
    }

    private static func needsReview(
        _ segment: TranscriptSegment,
        recording: RecordingManifest
    ) -> Bool {
        if let confidence = segment.transcriptionConfidence,
           confidence < reviewConfidenceThreshold {
            return true
        }
        let reliesOnDiarization = recording.effectiveOrigin == .importedAudio
            || segment.channel == 0
        guard reliesOnDiarization else { return false }
        if segment.speaker == nil { return true }
        if let confidence = segment.speakerConfidence,
           confidence < reviewConfidenceThreshold {
            return true
        }
        return false
    }

    private static func markdownInline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func duration(_ seconds: Double) -> String {
        String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            seconds
        )
    }

    private static func humanDate(_ date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return formatter.string(from: date)
    }

    private static func yaml(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

private struct DeepgramResponse: Decodable {
    var results: DeepgramResults
}

private struct DeepgramResults: Decodable {
    var channels: [DeepgramChannel]
    var utterances: [DeepgramUtterance]?
}

private struct DeepgramChannel: Decodable {
    var alternatives: [DeepgramAlternative]
}

private struct DeepgramAlternative: Decodable {
    var transcript: String
    var confidence: Double?
    var words: [DeepgramWord]?
    var paragraphs: DeepgramParagraphCollection?
}

private struct DeepgramParagraphCollection: Decodable {
    var paragraphs: [DeepgramParagraph]
}

private struct DeepgramParagraph: Decodable {
    var sentences: [DeepgramSentence]
    var speaker: Int?
    var start: Double
    var end: Double
}

private struct DeepgramSentence: Decodable {
    var text: String
}

private struct DeepgramUtterance: Decodable {
    var start: Double
    var end: Double
    var channel: FlexibleInteger?
    var speaker: Int?
    var transcript: String
    var confidence: Double?
    var words: [DeepgramWord]?
}

private struct DeepgramWord: Decodable {
    var word: String
    var punctuatedWord: String?
    var start: Double
    var end: Double
    var speaker: Int?
    var confidence: Double?
    var speakerConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case word
        case punctuatedWord = "punctuated_word"
        case start
        case end
        case speaker
        case confidence
        case speakerConfidence = "speaker_confidence"
    }
}

private struct FlexibleInteger: Decodable {
    var value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            value = integer
        } else if let integers = try? container.decode([Int].self), let first = integers.first {
            value = first
        } else if let string = try? container.decode(String.self), let integer = Int(string) {
            value = integer
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected an integer channel identifier."
                )
            )
        }
    }
}
