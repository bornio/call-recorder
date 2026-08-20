import Foundation
@testable import CallRecorderCore

@MainActor
func runCalendarMatchingTests() throws {
    let now = Date(timeIntervalSince1970: 10_000)

    try runTest("one plausible meeting is selected automatically") {
        let current = event(
            "current",
            start: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(1_200)
        )
        let tooFarAway = event(
            "later",
            start: now.addingTimeInterval(900),
            end: now.addingTimeInterval(2_700)
        )

        let match = CalendarEventMatchPolicy.matchAtRecordingStart(
            from: [tooFarAway, current],
            now: now
        )

        try expectEqual(match.candidates.map(\.identifier), ["current"])
        try expectEqual(match.automaticSelection?.identifier, "current")
        try expect(!match.needsReview)
    }

    try runTest("back-to-back overrun boundary stays unresolved") {
        let previous = event(
            "previous",
            start: now.addingTimeInterval(-2_100),
            end: now.addingTimeInterval(-300)
        )
        let current = event(
            "current",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1_500)
        )

        let match = CalendarEventMatchPolicy.matchAtRecordingStart(
            from: [current, previous],
            now: now
        )

        try expectEqual(match.candidates.map(\.identifier), ["previous", "current"])
        try expectEqual(match.automaticSelection, nil)
        try expect(match.needsReview)
    }

    try runTest("early join and overrun windows are bounded") {
        let justEnded = event(
            "just-ended",
            start: now.addingTimeInterval(-2_100),
            end: now.addingTimeInterval(-1_140)
        )
        let startingSoon = event(
            "soon",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(2_400)
        )
        let endedTooLongAgo = event(
            "old",
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1_260)
        )
        let startingTooLate = event(
            "later",
            start: now.addingTimeInterval(660),
            end: now.addingTimeInterval(2_460)
        )

        let match = CalendarEventMatchPolicy.matchAtRecordingStart(
            from: [startingTooLate, endedTooLongAgo, startingSoon, justEnded],
            now: now
        )

        try expectEqual(match.candidates.map(\.identifier), ["just-ended", "soon"])
        try expect(match.needsReview)
    }

    try runTest("calendar matching ignores invalid events and duplicate identifiers") {
        let valid = event(
            "valid",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(900)
        )
        let candidates = [
            valid,
            valid,
            CalendarEventCandidate(
                identifier: "all-day",
                title: "Holiday",
                startDate: now,
                endDate: now.addingTimeInterval(86_400),
                isAllDay: true
            ),
            CalendarEventCandidate(
                identifier: "cancelled",
                title: "Cancelled",
                startDate: now,
                endDate: now.addingTimeInterval(1_800),
                isCancelled: true
            ),
            CalendarEventCandidate(
                identifier: "blank",
                title: "   ",
                startDate: now,
                endDate: now.addingTimeInterval(1_800)
            ),
        ]

        let match = CalendarEventMatchPolicy.matchAtRecordingStart(
            from: candidates,
            now: now
        )

        try expectEqual(match.candidates, [valid])
        try expectEqual(match.automaticSelection, valid)
    }

    try runTest("recording interval resolves a clear overrun to its starting meeting") {
        let first = event(
            "first",
            start: now,
            end: now.addingTimeInterval(1_800)
        )
        let second = event(
            "second",
            start: now.addingTimeInterval(1_800),
            end: now.addingTimeInterval(3_600)
        )

        let resolved = CalendarEventMatchPolicy.resolveAfterRecording(
            from: [first, second],
            recordingStart: now.addingTimeInterval(300),
            recordingEnd: now.addingTimeInterval(2_520)
        )

        try expectEqual(resolved?.identifier, "first")
    }

    try runTest("short boundary recording remains unresolved") {
        let first = event(
            "first",
            start: now,
            end: now.addingTimeInterval(1_800)
        )
        let second = event(
            "second",
            start: now.addingTimeInterval(1_800),
            end: now.addingTimeInterval(3_600)
        )

        let resolved = CalendarEventMatchPolicy.resolveAfterRecording(
            from: [first, second],
            recordingStart: now.addingTimeInterval(2_040),
            recordingEnd: now.addingTimeInterval(2_820)
        )

        try expectEqual(resolved, nil)
    }

    try runTest("recording extending past overrun grace resolves to the next meeting") {
        let first = event(
            "first",
            start: now,
            end: now.addingTimeInterval(1_800)
        )
        let second = event(
            "second",
            start: now.addingTimeInterval(1_800),
            end: now.addingTimeInterval(3_600)
        )

        let resolved = CalendarEventMatchPolicy.resolveAfterRecording(
            from: [first, second],
            recordingStart: now.addingTimeInterval(2_100),
            recordingEnd: now.addingTimeInterval(3_480)
        )

        try expectEqual(resolved?.identifier, "second")
    }
}

private func event(
    _ identifier: String,
    start: Date,
    end: Date
) -> CalendarEventCandidate {
    CalendarEventCandidate(
        identifier: identifier,
        title: identifier,
        startDate: start,
        endDate: end
    )
}
