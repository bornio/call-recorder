@testable import CallRecorderCore

func runRecorderStateMachineTests() throws {
    try runTest("normal recording and transcription flow") {
        var machine = RecorderStateMachine()
        try machine.transition(.start)
        try expectEqual(machine.phase, .recording)
        try machine.transition(.stop)
        try expectEqual(machine.phase, .processing)
        try machine.transition(.finalized(transcriptionRequired: true))
        try expectEqual(machine.phase, .transcribing)
        try machine.transition(.transcriptionSucceeded)
        try expectEqual(machine.phase, .complete)
    }

    try runTest("finalized recording can complete without credential") {
        var machine = RecorderStateMachine()
        try machine.transition(.start)
        try machine.transition(.stop)
        try machine.transition(.finalized(transcriptionRequired: false))
        try expectEqual(machine.phase, .complete)
    }

    try runTest("recording can pause, resume, and stop while paused") {
        var machine = RecorderStateMachine()
        try machine.transition(.start)
        try machine.transition(.pause)
        try expectEqual(machine.phase, .paused)
        try machine.transition(.resume)
        try expectEqual(machine.phase, .recording)
        try machine.transition(.pause)
        try machine.transition(.stop)
        try expectEqual(machine.phase, .processing)
    }

    try runTest("active recording can be cancelled") {
        var recording = RecorderStateMachine(phase: .recording)
        try recording.transition(.cancel)
        try expectEqual(recording.phase, .idle)

        var paused = RecorderStateMachine(phase: .paused)
        try paused.transition(.cancel)
        try expectEqual(paused.phase, .idle)
    }

    try runTest("retry can begin while app is idle") {
        var machine = RecorderStateMachine()
        try machine.transition(.retryTranscription)
        try expectEqual(machine.phase, .transcribing)
    }

    try runTest("recording recovery begins processing from a failed state") {
        var machine = RecorderStateMachine(phase: .failed)
        try machine.transition(.recoverFinalization)
        try expectEqual(machine.phase, .processing)
        try machine.transition(.finalized(transcriptionRequired: false))
        try expectEqual(machine.phase, .complete)
    }

    try runTest("stop is rejected when nothing is recording") {
        var machine = RecorderStateMachine()
        try expectThrows { try machine.transition(.stop) }
        try expectEqual(machine.phase, .idle)
    }
}
