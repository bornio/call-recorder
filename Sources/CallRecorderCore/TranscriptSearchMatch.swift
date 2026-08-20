import Foundation

public struct TranscriptSearchMatch: Equatable, Sendable {
    public enum Field: Equatable, Sendable {
        case speaker
        case text
    }

    public let segmentIndex: Int
    public let field: Field
    public let occurrenceIndex: Int

    public init(segmentIndex: Int, field: Field, occurrenceIndex: Int) {
        self.segmentIndex = segmentIndex
        self.field = field
        self.occurrenceIndex = occurrenceIndex
    }

    public static func find(
        in document: TranscriptDocument,
        query: String,
        speakerName: (TranscriptSegment) -> String
    ) -> [TranscriptSearchMatch] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        return document.segments.enumerated().flatMap { segmentIndex, segment in
            let speakerMatches = matches(
                in: speakerName(segment),
                query: query,
                segmentIndex: segmentIndex,
                field: .speaker
            )
            let textMatches = matches(
                in: segment.text,
                query: query,
                segmentIndex: segmentIndex,
                field: .text
            )
            return speakerMatches + textMatches
        }
    }

    private static func matches(
        in value: String,
        query: String,
        segmentIndex: Int,
        field: Field
    ) -> [TranscriptSearchMatch] {
        var matches: [TranscriptSearchMatch] = []
        var searchStart = value.startIndex

        while searchStart < value.endIndex,
              let range = value.range(
                  of: query,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart..<value.endIndex
              ) {
            matches.append(
                TranscriptSearchMatch(
                    segmentIndex: segmentIndex,
                    field: field,
                    occurrenceIndex: matches.count
                )
            )
            searchStart = range.upperBound
        }

        return matches
    }
}
