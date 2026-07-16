public enum TranscriptionRetryPolicy {
    public static func canRetry(_ recording: RecordingManifest) -> Bool {
        recording.captureStatus == .complete &&
            recording.files.audio != nil &&
            recording.transcriptionStatus == .failed
    }
}

public enum FinalizationRecoveryPolicy {
    public static func canRecover(
        _ recording: RecordingManifest,
        hasRecoverableCapture: Bool
    ) -> Bool {
        recording.effectiveOrigin == .nativeRecording &&
            recording.files.audio == nil &&
            hasRecoverableCapture &&
            (recording.captureStatus == .processing ||
                (recording.captureStatus == .failed &&
                    (recording.lastFailure?.stage == .finalization ||
                        recording.lastFailure?.stage == .capture)))
    }
}
