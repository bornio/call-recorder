import Foundation

/// A real timed range in the exact displayed paragraph, using Cocoa's UTF-16 ranges.
public struct TranscriptTimedText: Equatable, Sendable {
    public var range: NSRange
    public var start: Double
    public var end: Double

    public init(range: NSRange, start: Double, end: Double) {
        self.range = range
        self.start = start
        self.end = end
    }
}

public struct TranscriptPlaybackTimeline: Sendable {
    public struct Entry: Equatable, Sendable {
        public let segmentIndex: Int
        public let text: TranscriptTimedText
    }

    public let entries: [Entry]
    private let maximumEnds: [Double]

    public init(document: TranscriptDocument) {
        entries = document.segments.enumerated().flatMap { index, segment in
            let spans = segment.timedText.isEmpty
                ? [TranscriptTimedText(
                    range: NSRange(location: 0, length: segment.text.utf16.count),
                    start: segment.start, end: segment.end
                )]
                : segment.timedText
            return spans.filter {
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start &&
                    $0.range.location >= 0 && $0.range.length > 0 &&
                    $0.range.location <= segment.text.utf16.count &&
                    $0.range.length <= segment.text.utf16.count - $0.range.location
            }.map { Entry(segmentIndex: index, text: $0) }
        }.sorted {
            if $0.text.start != $1.text.start { return $0.text.start < $1.text.start }
            if $0.segmentIndex != $1.segmentIndex { return $0.segmentIndex < $1.segmentIndex }
            return $0.text.range.location < $1.text.range.location
        }
        var maximum: Double = 0
        maximumEnds = entries.map { maximum = max(maximum, $0.text.end); return maximum }
    }

    /// Half-open intervals preserve silence and simultaneous speakers. A small AAC
    /// duration rounding tolerance does not stretch or otherwise alter transcript time.
    public func activeEntries(at time: Double, duration: Double) -> [Entry] {
        guard time.isFinite, duration.isFinite, time >= 0, time < duration else { return [] }
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entries[middle].text.start <= time { lower = middle + 1 } else { upper = middle }
        }
        var result: [Entry] = []
        var index = lower - 1
        while index >= 0, maximumEnds[index] > time {
            let entry = entries[index]
            if time < entry.text.end, entry.text.end <= duration + 0.25 {
                result.append(entry)
            }
            index -= 1
        }
        return result.reversed()
    }
}
