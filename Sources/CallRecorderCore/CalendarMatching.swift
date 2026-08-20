import Foundation

public struct CalendarEventCandidate: Codable, Equatable, Identifiable, Sendable {
    public var identifier: String
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var attendeeNames: [String]
    public var calendarName: String?
    public var isAllDay: Bool
    public var isCancelled: Bool

    public var id: String { identifier }

    public init(
        identifier: String,
        title: String,
        startDate: Date,
        endDate: Date,
        attendeeNames: [String] = [],
        calendarName: String? = nil,
        isAllDay: Bool = false,
        isCancelled: Bool = false
    ) {
        self.identifier = identifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.attendeeNames = attendeeNames
        self.calendarName = calendarName
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
    }
}

public struct CalendarStartMatch: Equatable, Sendable {
    public var candidates: [CalendarEventCandidate]
    public var automaticSelection: CalendarEventCandidate?

    public init(
        candidates: [CalendarEventCandidate],
        automaticSelection: CalendarEventCandidate?
    ) {
        self.candidates = candidates
        self.automaticSelection = automaticSelection
    }

    public var needsReview: Bool {
        candidates.count > 1 && automaticSelection == nil
    }
}

public enum CalendarEventMatchPolicy {
    public static let earlyJoinTolerance: TimeInterval = 10 * 60
    public static let overrunTolerance: TimeInterval = 20 * 60

    public static func matchAtRecordingStart(
        from candidates: [CalendarEventCandidate],
        now: Date,
        earlyJoinTolerance: TimeInterval = earlyJoinTolerance,
        overrunTolerance: TimeInterval = overrunTolerance
    ) -> CalendarStartMatch {
        let earliestPreviousEnd = now.addingTimeInterval(-max(0, overrunTolerance))
        let latestUpcomingStart = now.addingTimeInterval(max(0, earlyJoinTolerance))
        let plausible = normalized(candidates).filter { candidate in
            let isPreviousOverrun = candidate.endDate <= now &&
                candidate.endDate >= earliestPreviousEnd
            let isCurrent = candidate.startDate <= now && candidate.endDate > now
            let isEarlyJoin = candidate.startDate > now &&
                candidate.startDate <= latestUpcomingStart
            return isPreviousOverrun || isCurrent || isEarlyJoin
        }

        return CalendarStartMatch(
            candidates: plausible,
            automaticSelection: plausible.count == 1 ? plausible[0] : nil
        )
    }

    public static func resolveAfterRecording(
        from candidates: [CalendarEventCandidate],
        recordingStart: Date,
        recordingEnd: Date,
        earlyJoinTolerance: TimeInterval = earlyJoinTolerance,
        overrunTolerance: TimeInterval = overrunTolerance,
        minimumCoverage: Double = 0.6,
        minimumLead: Double = 0.25
    ) -> CalendarEventCandidate? {
        let duration = recordingEnd.timeIntervalSince(recordingStart)
        guard duration > 0 else { return nil }

        let scored = normalized(candidates).map { candidate in
            let plausibleStart = candidate.startDate.addingTimeInterval(
                -max(0, earlyJoinTolerance)
            )
            let plausibleEnd = candidate.endDate.addingTimeInterval(
                max(0, overrunTolerance)
            )
            let overlapStart = max(recordingStart, plausibleStart)
            let overlapEnd = min(recordingEnd, plausibleEnd)
            let overlap = max(0, overlapEnd.timeIntervalSince(overlapStart))
            return (candidate: candidate, coverage: overlap / duration)
        }.sorted {
            if $0.coverage == $1.coverage {
                return $0.candidate.startDate < $1.candidate.startDate
            }
            return $0.coverage > $1.coverage
        }

        guard let winner = scored.first,
              winner.coverage >= minimumCoverage
        else { return nil }
        if scored.count > 1,
           winner.coverage - scored[1].coverage < minimumLead {
            return nil
        }
        return winner.candidate
    }

    private static func normalized(
        _ candidates: [CalendarEventCandidate]
    ) -> [CalendarEventCandidate] {
        let eligible = candidates.filter { candidate in
            !candidate.identifier.isEmpty &&
                !candidate.isAllDay &&
                !candidate.isCancelled &&
                candidate.endDate > candidate.startDate &&
                !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted {
            if $0.startDate == $1.startDate { return $0.endDate < $1.endDate }
            return $0.startDate < $1.startDate
        }
        var identifiers: Set<String> = []
        return eligible.filter { identifiers.insert($0.identifier).inserted }
    }
}
