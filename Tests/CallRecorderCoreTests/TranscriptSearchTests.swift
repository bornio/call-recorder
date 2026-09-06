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
            TranscriptSearchMatch(segmentIndex: 0, field: .text, range: NSRange(location: 0, length: 5)),
            TranscriptSearchMatch(segmentIndex: 0, field: .text, range: NSRange(location: 11, length: 5)),
            TranscriptSearchMatch(segmentIndex: 1, field: .speaker, range: NSRange(location: 0, length: 5)),
        ])
    }

    try runTest("transcript search trims the query and ignores case and accents") {
        let document = TranscriptDocument(segments: [
            TranscriptSegment(
                start: 0,
                end: 4,
                channel: 0,
                speaker: 0,
                text: "😀 Cafe and CAFE\u{301}"
            ),
        ])

        let matches = TranscriptSearchMatch.find(
            in: document,
            query: "  café  ",
            speakerName: { _ in "Speaker" }
        )

        try expectEqual(matches, [
            TranscriptSearchMatch(segmentIndex: 0, field: .text, range: NSRange(location: 3, length: 4)),
            TranscriptSearchMatch(segmentIndex: 0, field: .text, range: NSRange(location: 12, length: 5)),
        ])
    }

    try runTest("search filtering agrees with Unicode match ranges and speaker edits") {
        let document = TranscriptDocument(segments: [
            TranscriptSegment(start: 0, end: 1, channel: 0, speaker: 0, text: "İ café"),
        ])
        for query in ["i", "cafe"] {
            let matches = TranscriptSearchMatch.find(in: document, query: query) { _ in "Speaker" }
            try expect(TranscriptSearchMatch.contains(query, in: document.segments[0].text))
            try expectEqual(matches.count, 1)
        }
        let original = TranscriptSearchMatch.find(in: document, query: "cafe") { _ in "Café" }
        let renamed = TranscriptSearchMatch.find(in: document, query: "cafe") { _ in "😀 Café" }
        try expectEqual(original[0].range, NSRange(location: 0, length: 4))
        try expectEqual(renamed[0].range, NSRange(location: 3, length: 4))
        try expectEqual(original[1], renamed[1])
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
