import Foundation
@testable import CallRecorderCore

@MainActor
func runTranscriptSearchTests() throws {
    try runTest("transcript search finds each visible occurrence in reading order") {
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                start: 0,
                end: 4,
                channel: 0,
                speaker: 0,
                text: "Alpha then ALPHA"
            ),
            TranscriptSegment(
                start: 5,
                end: 8,
                channel: 0,
                speaker: 1,
                text: "Nothing here"
            ),
        ])

        let matches = TranscriptSearchMatch.find(
            in: document,
            query: "alpha",
            speakerName: { $0.speaker == 1 ? "Alpha" : "Alex" }
        )

        try expectEqual(matches, [
            TranscriptSearchMatch(segmentIndex: 0, field: .text, occurrenceIndex: 0),
            TranscriptSearchMatch(segmentIndex: 0, field: .text, occurrenceIndex: 1),
            TranscriptSearchMatch(segmentIndex: 1, field: .speaker, occurrenceIndex: 0),
        ])
    }

    try runTest("transcript search trims the query and ignores case and accents") {
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                start: 0,
                end: 4,
                channel: 0,
                speaker: 0,
                text: "Cafe and CAFÉ"
            ),
        ])

        let matches = TranscriptSearchMatch.find(
            in: document,
            query: "  café  ",
            speakerName: { _ in "Speaker" }
        )

        try expectEqual(matches, [
            TranscriptSearchMatch(segmentIndex: 0, field: .text, occurrenceIndex: 0),
            TranscriptSearchMatch(segmentIndex: 0, field: .text, occurrenceIndex: 1),
        ])
    }

    try runTest("transcript search ignores an empty query") {
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                start: 0,
                end: 4,
                channel: 0,
                speaker: 0,
                text: "Anything"
            ),
        ])

        let matches = TranscriptSearchMatch.find(
            in: document,
            query: "   ",
            speakerName: { _ in "Speaker" }
        )

        try expect(matches.isEmpty)
    }
}
