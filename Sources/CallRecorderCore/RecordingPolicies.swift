public enum TranscriptionRetryPolicy {
    public static func canRetry(_ recording: RecordingManifest) -> Bool {
        recording.captureStatus == .complete &&
            recording.files.audio != nil &&
            recording.transcriptionStatus != .transcribing &&
            recording.transcriptionStatus != .complete
    }
}

public enum FinalizationRecoveryPolicy {
    public static func canRecover(_ recording: RecordingManifest) -> Bool {
        recording.effectiveOrigin == .nativeRecording &&
            recording.files.audio == nil &&
            (recording.captureStatus == .processing ||
                (recording.captureStatus == .failed &&
                    recording.lastFailure?.stage == .finalization))
    }
}
