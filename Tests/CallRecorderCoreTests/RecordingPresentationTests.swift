import Foundation
@testable import CallRecorderCore

func runRecordingPresentationTests() throws {
    try runTest("recording presentation reports audio and transcript independently") {
        var recording = RecordingManifest(
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic"
        )

        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Recording")
        try expectEqual(recording.transcriptStatusText, "Waiting")

        recording.captureStatus = .processing
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Finishing")

        recording.captureStatus = .complete
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Unavailable")
        recording.files.audio = "/tmp/Audio.m4a"
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Saved")

        recording.captureStatus = .failed
        try expectEqual(recording.audioStatusText(hasRecoveryAudio: false), "Saved with errors")
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

        recording.files.audio = nil
        try expectEqual(recording.importedSourceFilename, nil)
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
