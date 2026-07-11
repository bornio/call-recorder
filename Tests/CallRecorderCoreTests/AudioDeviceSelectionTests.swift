@preconcurrency import CoreAudio
@testable import CallRecorderCore

func runAudioDeviceSelectionTests() throws {
    let defaultMicrophone = AudioInputDevice(
        id: 1,
        uid: "default",
        name: "Default microphone"
    )
    let callMicrophone = AudioInputDevice(
        id: 2,
        uid: "call",
        name: "Call microphone",
        isInUse: true
    )

    try runTest("automatic microphone reuses the sole input already in use") {
        let selected = AudioDeviceService.preferredInputDevice(
            from: [defaultMicrophone, callMicrophone],
            defaultDeviceID: defaultMicrophone.id
        )
        try expectEqual(selected?.uid, callMicrophone.uid)
    }

    try runTest("automatic microphone prefers the running default when use is ambiguous") {
        var runningDefault = defaultMicrophone
        runningDefault.isInUse = true
        let selected = AudioDeviceService.preferredInputDevice(
            from: [runningDefault, callMicrophone],
            defaultDeviceID: runningDefault.id
        )
        try expectEqual(selected?.uid, runningDefault.uid)
    }

    try runTest("automatic microphone falls back to the current system default") {
        let selected = AudioDeviceService.preferredInputDevice(
            from: [callMicrophone.withUsage(false), defaultMicrophone],
            defaultDeviceID: defaultMicrophone.id
        )
        try expectEqual(selected?.uid, defaultMicrophone.uid)
    }
}

private extension AudioInputDevice {
    func withUsage(_ isInUse: Bool) -> AudioInputDevice {
        var copy = self
        copy.isInUse = isInUse
        return copy
    }
}
