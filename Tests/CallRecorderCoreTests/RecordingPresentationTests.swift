import Foundation
@testable import CallRecorderCore

@MainActor
func runRecordingPresentationTests() throws {
    try runTest("recording presentation reports audio and transcript independently") {
        var recording = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic"
        )

        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Recording")
        try expectEqual(recording.transcriptStatusText, "Waiting")
        try expect(!recording.hasFailure)
        try expect(!recording.isProcessing)
        try expect(!recording.requiresAttention)

        recording.captureStatus = .processing
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Finishing")
        try expect(recording.isProcessing)

        recording.captureStatus = .complete
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Unavailable")
        recording.files.audio = "/tmp/Audio.m4a"
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Saved")

        recording.captureStatus = .failed
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Saved with errors")
        try expect(recording.hasFailure)
        try expect(recording.requiresAttention)
        recording.files.audio = nil
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: true), "Recovery retained")
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Failed")

        recording.transcriptionStatus = .waitingForCredential
        try expectEqual(recording.transcriptStatusText, "Needs key")
        recording.transcriptionStatus = .transcribing
        try expectEqual(recording.transcriptStatusText, "Transcribing")
        recording.transcriptionStatus = .complete
        try expectEqual(recording.transcriptStatusText, "Ready")
        recording.transcriptionStatus = .failed
        try expectEqual(recording.transcriptStatusText, "Failed")

        var waitingForKey = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic"
        )
        waitingForKey.captureStatus = .complete
        waitingForKey.transcriptionStatus = .waitingForCredential
        try expect(waitingForKey.requiresAttention)
    }

    try runTest("imported recording presentation uses the source filename") {
        var recording = RecordingManifest(
            language: .hebrew,
            microphoneUID: "",
            microphoneName: "Imported audio"
        )
        recording.origin = .importedAudio
        recording.files.audio = "/tmp/Customer sync.m4a"
        try expectEqual(recording.importedSourceFilename, "Customer sync.m4a")
        try expectEqual(recording.displayTitle, "Customer sync")

        recording.files.audio = nil
        try expectEqual(recording.importedSourceFilename, nil)
    }

    try runTest("recording titles and speaker labels normalize without breaking old manifests") {
        var recording = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic",
            localSpeakerName: "Taylor"
        )
        try expectEqual(recording.displayTitle, "Untitled recording")

        recording.title = "  Product\nroadmap   review  "
        try expectEqual(recording.displayTitle, "Product roadmap review")
        recording.setSpeakerName("  Morgan   Lee ", channel: 0, speaker: 3)
        try expectEqual(recording.speakerDisplayName(channel: 0, speaker: 3), "Morgan Lee")
        try expectEqual(recording.speakerDisplayName(channel: 1, speaker: 0), "Taylor")
        recording.setSpeakerName("", channel: 0, speaker: 3)
        try expectEqual(recording.speakerDisplayName(channel: 0, speaker: 3), "Speaker 3")

        let encoded = try JSONEncoder().encode(recording)
        var json = try require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in [
            "title",
            "titleSource",
            "meetingAssociationState",
            "calendarCandidates",
            "calendarEventIdentifier",
            "calendarTitle",
            "calendarStartDate",
            "calendarEndDate",
            "calendarAttendeeNames",
            "speakerLabels",
        ] {
            json.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(RecordingManifest.self, from: legacyData)
        try expectEqual(decoded.displayTitle, "Untitled recording")
        try expectEqual(decoded.calendarEventIdentifier, nil)
        try expectEqual(decoded.effectiveMeetingAssociationState, .none)
        try expectEqual(decoded.speakerLabels, nil)
    }

    try runTest("meeting reassignment preserves user titles and replaces calendar titles") {
        let first = CalendarEventCandidate(
            identifier: "first",
            title: "First meeting",
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 200),
            attendeeNames: ["Taylor"]
        )
        let second = CalendarEventCandidate(
            identifier: "second",
            title: "Second meeting",
            startDate: Date(timeIntervalSince1970: 300),
            endDate: Date(timeIntervalSince1970: 400),
            attendeeNames: ["Morgan"]
        )
        var recording = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic"
        )

        recording.assignMeeting(first, state: .automatic, updateCalendarTitle: true)
        try expectEqual(recording.displayTitle, "First meeting")
        try expectEqual(recording.effectiveTitleSource, .calendar)

        recording.assignMeeting(second, state: .manual, updateCalendarTitle: true)
        try expectEqual(recording.displayTitle, "Second meeting")
        try expectEqual(recording.calendarAttendeeNames, ["Morgan"])

        recording.title = "My own title"
        recording.titleSource = .user
        recording.assignMeeting(first, state: .manual, updateCalendarTitle: true)
        try expectEqual(recording.displayTitle, "My own title")
        try expectEqual(recording.calendarTitle, "First meeting")

        recording.clearMeetingAssociation()
        try expectEqual(recording.displayTitle, "My own title")
        try expectEqual(recording.effectiveMeetingAssociationState, .none)
        try expectEqual(recording.calendarEventIdentifier, nil)
        try expectEqual(recording.calendarTitle, nil)
        try expectEqual(recording.calendarStartDate, nil)
        try expectEqual(recording.calendarEndDate, nil)
        try expectEqual(recording.calendarAttendeeNames, nil)
        try expectEqual(recording.calendarCandidates, nil)

        var calendarTitled = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic"
        )
        calendarTitled.assignMeeting(first, state: .automatic, updateCalendarTitle: true)
        calendarTitled.clearMeetingAssociation()
        try expectEqual(calendarTitled.displayTitle, "Untitled recording")
        try expectEqual(calendarTitled.effectiveTitleSource, nil)
    }

    try runTest("recording health presentation uses structured capture facts") {
        var recording = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic"
        )
        recording.warnings = ["Private finalizer diagnostic"]
        try expectEqual(recording.captureHealthSummary, nil)

        recording.captureSummary.systemDroppedFrames = 48
        try expect(recording.requiresAttention)
        try expectEqual(
            recording.captureHealthSummary,
            "48 audio frames were dropped. Audio may contain gaps."
        )

        recording.routeBefore = AudioRouteSnapshot(
            defaultInputDevice: 1,
            defaultOutputDevice: 2
        )
        recording.routeAfter = AudioRouteSnapshot(
            defaultInputDevice: 1,
            defaultOutputDevice: 3
        )
        try expectEqual(
            recording.captureHealthSummary,
            "48 audio frames were dropped. Audio may contain gaps. " +
                "The default output device changed during recording."
        )
    }
}
