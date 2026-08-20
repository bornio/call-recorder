import CallRecorderCore
import Foundation
import SwiftUI

enum RecordingDetailSection: String, CaseIterable, Identifiable {
    case transcript
    case info

    var id: String { rawValue }
}

struct StatusLabel: View {
    let recording: RecordingManifest

    var body: some View {
        Label(recording.transcriptStatusText, systemImage: systemImage)
            .foregroundStyle(color)
    }

    private var systemImage: String {
        if recording.hasFailure {
            return "exclamationmark.circle.fill"
        }
        if recording.transcriptionStatus == .complete { return "checkmark.circle.fill" }
        if recording.transcriptionStatus == .waitingForCredential { return "key.fill" }
        return "clock"
    }

    private var color: Color {
        if recording.hasFailure {
            return .red
        }
        if recording.transcriptionStatus == .complete { return .green }
        if recording.transcriptionStatus == .waitingForCredential { return .orange }
        return .secondary
    }
}

struct MeetingAssociationMenu: View {
    @EnvironmentObject private var model: AppModel
    let recording: RecordingManifest

    var body: some View {
        Menu {
            if choices.isEmpty {
                Text("No nearby calendar events")
            } else {
                ForEach(choices) { event in
                    Button {
                        model.assignMeeting(event, to: recording)
                    } label: {
                        if event.identifier == recording.calendarEventIdentifier {
                            Label(menuTitle(for: event), systemImage: "checkmark")
                        } else {
                            Text(menuTitle(for: event))
                        }
                    }
                }
            }

            Divider()

            Button("No calendar meeting") {
                model.clearMeetingAssociation(for: recording)
            }

            if model.calendarSuggestionsEnabled,
               model.calendarAccessState == .fullAccess {
                Button("Refresh nearby meetings") {
                    model.refreshMeetingChoices(for: recording)
                }
            } else {
                SettingsLink { Text("Calendar Settings…") }
            }
        } label: {
            Label(selectionTitle, systemImage: systemImage)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 220, alignment: .trailing)
        .disabled(!model.canEditMetadata(for: recording))
        .help(helpText)
        .accessibilityLabel("Meeting association")
        .accessibilityValue(selectionTitle)
    }

    private var choices: [CalendarEventCandidate] {
        model.meetingChoices(for: recording)
    }

    private var selectionTitle: String {
        switch recording.effectiveMeetingAssociationState {
        case .automatic, .manual:
            recording.calendarTitle ?? "Calendar meeting"
        case .unresolved:
            "Choose meeting…"
        case .none:
            "Add meeting…"
        }
    }

    private var systemImage: String {
        recording.effectiveMeetingAssociationState == .unresolved
            ? "calendar.badge.exclamationmark"
            : "calendar"
    }

    private var helpText: String {
        switch recording.effectiveMeetingAssociationState {
        case .automatic:
            "Automatically associated. Choose a different meeting if needed."
        case .manual:
            "Manually associated. Choose a different meeting if needed."
        case .unresolved:
            "More than one meeting fits this recording."
        case .none:
            "Associate this recording with a calendar meeting."
        }
    }

    private func menuTitle(for event: CalendarEventCandidate) -> String {
        let title = event.title.count > 30
            ? String(event.title.prefix(27)) + "..."
            : event.title
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = recording.timeZoneIdentifier
            .flatMap { TimeZone(identifier: $0) } ?? .current
        return [
            title,
            formatter.string(from: event.startDate),
            event.calendarName,
        ].compactMap { $0 }.joined(separator: " · ")
    }
}
