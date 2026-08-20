@preconcurrency import EventKit
import CallRecorderCore
import Foundation

enum CalendarAccessState: Equatable, Sendable {
    case notDetermined
    case fullAccess
    case writeOnly
    case denied
    case restricted
    case unavailable
}

struct CalendarDescriptor: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var sourceTitle: String
}

actor CalendarReader {
    private let eventStore = EKEventStore()

    func accessState() -> CalendarAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            .notDetermined
        case .fullAccess:
            .fullAccess
        case .writeOnly:
            .writeOnly
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .unavailable
        }
    }

    func requestFullAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    func availableCalendars() -> [CalendarDescriptor] {
        guard accessState() == .fullAccess,
              !Task.isCancelled
        else { return [] }
        return eventStore.calendars(for: .event)
            .map {
                CalendarDescriptor(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source.title
                )
            }
            .sorted {
                if $0.sourceTitle == $1.sourceTitle { return $0.title < $1.title }
                return $0.sourceTitle < $1.sourceTitle
            }
    }

    func eventsNearRecordingStart(
        now: Date,
        selectedCalendarIDs: Set<String>
    ) -> [CalendarEventCandidate] {
        events(
            from: now.addingTimeInterval(-12 * 60 * 60),
            through: now.addingTimeInterval(90 * 60),
            selectedCalendarIDs: selectedCalendarIDs
        )
    }

    func eventsAroundRecording(
        startDate: Date,
        endDate: Date,
        selectedCalendarIDs: Set<String>
    ) -> [CalendarEventCandidate] {
        events(
            from: startDate.addingTimeInterval(-2 * 60 * 60),
            through: endDate.addingTimeInterval(2 * 60 * 60),
            selectedCalendarIDs: selectedCalendarIDs
        )
    }

    private func events(
        from startDate: Date,
        through endDate: Date,
        selectedCalendarIDs: Set<String>
    ) -> [CalendarEventCandidate] {
        guard accessState() == .fullAccess,
              !selectedCalendarIDs.isEmpty,
              endDate > startDate,
              !Task.isCancelled
        else { return [] }

        let calendars = eventStore.calendars(for: .event).filter {
            selectedCalendarIDs.contains($0.calendarIdentifier)
        }
        guard !calendars.isEmpty else { return [] }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )
        guard !Task.isCancelled else { return [] }
        let matchingEvents = eventStore.events(matching: predicate)
        guard !Task.isCancelled else { return [] }
        return matchingEvents.map { event in
            CalendarEventCandidate(
                identifier: eventIdentifier(for: event),
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                attendeeNames: attendeeNames(for: event),
                calendarName: event.calendar.title,
                isAllDay: event.isAllDay,
                isCancelled: event.status == .canceled
            )
        }.filter { candidate in
            !candidate.isAllDay &&
                !candidate.isCancelled &&
                candidate.endDate > candidate.startDate &&
                !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted {
            if $0.startDate == $1.startDate { return $0.endDate < $1.endDate }
            return $0.startDate < $1.startDate
        }
    }

    private func eventIdentifier(for event: EKEvent) -> String {
        let identifier = (event.eventIdentifier ?? event.calendarItemExternalIdentifier) ?? ""
        if !identifier.isEmpty { return identifier }
        return [
            event.calendar.calendarIdentifier,
            String(event.startDate.timeIntervalSinceReferenceDate),
            event.title ?? "Untitled event",
        ].joined(separator: "|")
    }

    private func attendeeNames(for event: EKEvent) -> [String] {
        var seen: Set<String> = []
        return (event.attendees ?? []).compactMap { attendee in
            let name = (attendee.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return name
        }
    }
}
