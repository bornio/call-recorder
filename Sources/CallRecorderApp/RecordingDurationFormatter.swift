import Foundation

func formattedRecordingDuration(_ interval: TimeInterval) -> String {
    guard interval.isFinite, interval < Double(Int.max) else { return "—" }
    let seconds = Int(max(0, interval).rounded(.down))
    if seconds >= 3_600 {
        return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
