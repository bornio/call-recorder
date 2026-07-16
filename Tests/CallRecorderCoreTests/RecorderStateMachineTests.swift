@testable import CallRecorderCore

func runCaptureSessionStateMachineTests() throws {
    try runTest("capture starts and returns to ready before post-processing") {
        var machine = CaptureSessionStateMachine()
        try machine.transition(.startRequested)
        try expectEqual(machine.state, .starting)
        try machine.transition(.captureStarted)
        try expectEqual(machine.state, .recording)
        try machine.transition(.stopRequested)
        try expectEqual(machine.state, .stopping)
        try machine.transition(.stopped)
        try expectEqual(machine.state, .ready)
    }

    try runTest("recording can pause, resume, and stop while paused") {
        var machine = CaptureSessionStateMachine(state: .recording)
        try machine.transition(.pause)
        try expectEqual(machine.state, .paused)
        try machine.transition(.resume)
        try expectEqual(machine.state, .recording)
        try machine.transition(.pause)
        try machine.transition(.stopRequested)
        try expectEqual(machine.state, .stopping)
    }

    try runTest("failed startup restores capture readiness") {
        var machine = CaptureSessionStateMachine(state: .starting)
        try machine.transition(.startFailed)
        try expectEqual(machine.state, .ready)
    }

    try runTest("stop is rejected when nothing is recording") {
        var machine = CaptureSessionStateMachine()
        try expectThrows { try machine.transition(.stopRequested) }
        try expectEqual(machine.state, .ready)
    }
}
