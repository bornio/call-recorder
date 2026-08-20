import CallRecorderCore
import SwiftUI

struct BackgroundRecordingSummary: View {
    let recording: RecordingManifest
    let captureIsActive: Bool
    let activity: RecordingJobActivity?
    let action: () -> Void

    var body: some View {
        Group {
            if recording.transcriptionStatus == .waitingForCredential {
                SettingsLink {
                    summaryLabel
                }
                .accessibilityHint("Opens Settings to add a Deepgram key")
            } else {
                Button(action: action) {
                    summaryLabel
                }
                .accessibilityHint("Opens Recordings")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle)
        .accessibilityLabel(
            "\(captureIsActive ? "Previous recording" : "Recording"). \(title). \(detail)"
        )
    }

    private var summaryLabel: some View {
        HStack(alignment: .center, spacing: 10) {
            statusIcon
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(captureIsActive ? "Previous recording" : "Recording")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: recording.transcriptionStatus == .waitingForCredential
                ? "gearshape"
                : "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        if recording.transcriptionStatus == .waitingForCredential {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
        } else if recording.hasFailure {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if activeActivity != nil || recording.isProcessing {
            ProgressView()
                .controlSize(.small)
        } else if recording.captureHealthSummary != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if recording.transcriptionStatus == .complete {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if recording.transcriptionStatus == .waitingForCredential {
            return "Deepgram key needed"
        }
        if recording.hasFailure {
            return "Recording needs attention"
        }
        if case .finishingAudio = activeActivity {
            return "Audio secured locally"
        }
        if case .transcribing = activeActivity {
            return "Saved locally · Transcribing…"
        }
        if recording.captureStatus == .processing {
            return "Audio secured locally"
        }
        if recording.transcriptionStatus == .transcribing {
            return "Saved locally · Transcribing…"
        }
        if recording.captureStatus == .complete,
           recording.transcriptionStatus == .notStarted {
            return "Saved locally · Waiting to transcribe"
        }
        return "Transcript ready"
    }

    private var detail: String {
        if recording.transcriptionStatus == .waitingForCredential {
            if let captureHealthSummary = recording.captureHealthSummary {
                return "\(captureHealthSummary) Add a key to transcribe."
            }
            return "Add a key to start transcription."
        }
        if recording.hasFailure {
            return "Open Recordings for details."
        }
        if let captureHealthSummary = recording.captureHealthSummary {
            return captureHealthSummary
        }
        if case .finishingAudio = activeActivity {
            return "Finishing the audio file. You can record again."
        }
        if case .transcribing = activeActivity {
            return "You can start another recording."
        }
        if recording.captureStatus == .processing {
            return "Finishing the audio file. You can record again."
        }
        if recording.transcriptionStatus == .transcribing {
            return "You can start another recording."
        }
        if captureIsActive && recording.transcriptionStatus == .notStarted {
            return "Transcription starts when this recording ends."
        }
        return recording.displayTitle
    }

    private var activeActivity: RecordingJobActivity? {
        guard activity?.recordingID == recording.id else { return nil }
        return activity
    }
}
