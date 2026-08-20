import AppKit
import SwiftUI

@MainActor
func announceRecordingSearchMatch(index: Int, count: Int) {
    guard count > 0 else { return }
    let current = min(max(index, 0), count - 1) + 1
    NSAccessibility.post(
        element: NSApplication.shared,
        notification: .announcementRequested,
        userInfo: [
            .announcement: "Match \(current) of \(count)",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ]
    )
}

struct RecordingSearchNavigation {
    var canNavigate: Bool
    var previous: () -> Void
    var next: () -> Void
}

private struct RecordingSearchNavigationKey: FocusedValueKey {
    typealias Value = RecordingSearchNavigation
}

extension FocusedValues {
    var recordingSearchNavigation: RecordingSearchNavigation? {
        get { self[RecordingSearchNavigationKey.self] }
        set { self[RecordingSearchNavigationKey.self] = newValue }
    }
}

struct RecordingSearchCommands: Commands {
    @FocusedValue(\.recordingSearchNavigation) private var navigation

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()

            Button("Find Next") {
                navigation?.next()
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(navigation?.canNavigate != true)

            Button("Find Previous") {
                navigation?.previous()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(navigation?.canNavigate != true)
        }
    }
}
