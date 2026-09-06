import Foundation
@testable import CallRecorderCore

@MainActor
func runRecordingPlaybackTests() async throws {
    try runTest("sentence timing preserves Unicode text and exported Markdown") {
        let response = Data(#"""
        {"results":{"channels":[{"alternatives":[{"transcript":"שלום 👋. $25.","paragraphs":{"paragraphs":[
          {"start":1,"end":8,"sentences":[{"text":"  שלום 👋.","start":1,"end":3},{"text":"$25.  ","start":5,"end":8}]}
        ]}}]}]}}
        """#.utf8)
        let document = try TranscriptDocument(deepgramResponse: response)
        let paragraph = try require(document.segments.first)
        try expectEqual(paragraph.text, "שלום 👋. $25.")
        try expectEqual(paragraph.timedText.map { (paragraph.text as NSString).substring(with: $0.range) }, ["שלום 👋.", "$25."])
        var untimed = document
        untimed.segments[0].timedText = []
        let recording = RecordingManifest(createdAt: Date(timeIntervalSince1970: 0), language: .hebrew, microphoneUID: "mic", microphoneName: "Mic")
        try expectEqual(TranscriptMarkdownFormatter.format(document: document, recording: recording),
                        TranscriptMarkdownFormatter.format(document: untimed, recording: recording))
    }
    try runTest("playback mapping preserves sentence gaps and overlapping channels") {
        let document = TranscriptDocument(segments: [
            TranscriptSegment(start: 0, end: 20, channel: 0, speaker: 0, text: "One. Two.", timedText: [
                TranscriptTimedText(range: NSRange(location: 0, length: 4), start: 1, end: 3),
                TranscriptTimedText(range: NSRange(location: 5, length: 4), start: 10, end: 12),
            ]),
            TranscriptSegment(start: 2, end: 4, channel: 1, speaker: 0, text: "Yes."),
        ])
        let timeline = TranscriptPlaybackTimeline(document: document)
        try expectEqual(timeline.activeEntries(at: 0, duration: 20).count, 0)
        try expectEqual(timeline.activeEntries(at: 2.5, duration: 20).map(\.segmentIndex), [0, 1])
        try expectEqual(timeline.activeEntries(at: 3, duration: 20).map(\.segmentIndex), [1])
        try expectEqual(timeline.activeEntries(at: 7, duration: 20).count, 0)
        try expectEqual(timeline.activeEntries(at: 10, duration: 20).first?.text.range.location, 5)
        try expectEqual(timeline.activeEntries(at: 12, duration: 20).count, 0)
    }
    try runTest("untimed and invalid spans never fabricate playback mapping") {
        let timeline = TranscriptPlaybackTimeline(document: TranscriptDocument(segments: [
            TranscriptSegment(start: 0, end: 0, channel: 0, speaker: nil, text: "Untimed"),
            TranscriptSegment(start: -2, end: 4, channel: 0, speaker: nil, text: "Invalid"),
            TranscriptSegment(start: 1, end: 100, channel: 0, speaker: nil, text: "Wrong file"),
            TranscriptSegment(start: 2, end: 3, channel: 0, speaker: nil, text: "Valid"),
        ]))
        try expectEqual(timeline.activeEntries(at: 2.5, duration: 10).count, 1)
        try expectEqual(timeline.activeEntries(at: .nan, duration: 10).count, 0)
        try expectEqual(timeline.activeEntries(at: 10, duration: 10).count, 0)
    }
    try await runAsyncTest("paused seeks and scrubbing commit the latest target without autoplay") {
        try await withTemporaryDirectory(prefix: "Playback") { root in
            let url = root.appendingPathComponent("silence.wav")
            try writeReviewSilence(to: url)
            let player = RecordingAudioPlayerModel()
            await player.load(url: url)
            try expect(player.canSeek)
            try expectEqual(player.duration, 4)
            // A following Play/Pause command must retain a seek that has not yet
            // reached the audio actor, even within the same main-actor turn.
            player.seek(to: 2)
            player.togglePlayback()
            player.togglePlayback()
            try await waitForPlayback { abs(player.currentTime - 2) < 0.01 }
            try expect(!player.isPlaying)
            player.seek(to: 1)
            try await waitForPlayback { abs(player.currentTime - 1) < 0.01 }
            player.beginScrubbing()
            player.previewScrub(to: 2)
            player.previewScrub(to: 3)
            try expectEqual(player.previewTime, 3)
            try expectEqual(player.currentTime, 1)
            player.endScrubbing()
            try await waitForPlayback { abs(player.currentTime - 3) < 0.01 }
            try expect(!player.isPlaying)
            player.beginScrubbing()
            player.previewScrub(to: 0.2)
            player.endScrubbing(cancelled: true)
            try await waitForPlayback { player.previewTime == nil && abs(player.currentTime - 3) < 0.01 }
            player.suspend()
        }
    }
    try await runAsyncTest("playing seeks resume after scrub but capture invalidates pending resume") {
        try await withTemporaryDirectory(prefix: "Playback") { root in
            let url = root.appendingPathComponent("silence.wav")
            try writeReviewSilence(to: url)
            let player = RecordingAudioPlayerModel()
            await player.load(url: url)
            player.togglePlayback()
            try await waitForPlayback { player.isPlaying }
            player.seek(to: 1)
            try await waitForPlayback { player.currentTime >= 1 && player.currentTime < 1.3 }
            try expect(player.isPlaying)
            player.beginScrubbing()
            try await waitForPlayback { !player.isPlaying }
            player.previewScrub(to: 2)
            player.endScrubbing()
            try await waitForPlayback { player.isPlaying && player.currentTime >= 2 }
            player.beginScrubbing()
            player.previewScrub(to: 3)
            player.setPlaybackBlocked(true)
            player.endScrubbing()
            try await Task.sleep(for: .milliseconds(150))
            try expect(!player.isPlaying && !player.canSeek && player.previewTime == nil)
            player.setPlaybackBlocked(false)
            try expect(!player.isPlaying)
            player.suspend()
        }
    }
    try await runAsyncTest("end stays at duration and explicit replay starts from zero") {
        try await withTemporaryDirectory(prefix: "Playback") { root in
            let url = root.appendingPathComponent("silence.wav")
            try writeReviewSilence(to: url)
            let player = RecordingAudioPlayerModel()
            await player.load(url: url)
            player.seek(to: 3.9)
            try await waitForPlayback { player.currentTime >= 3.9 }
            player.togglePlayback()
            try await waitForPlayback { player.hasEnded }
            try expectEqual(player.currentTime, player.duration)
            try expect(!player.isPlaying)
            player.togglePlayback()
            try await waitForPlayback { player.isPlaying && player.currentTime < 1 }
            player.seek(to: 99)
            try await waitForPlayback { player.hasEnded && !player.isPlaying }
            player.suspend()
        }
    }
    try await runAsyncTest("switching files discards old seeks and failed loads cannot play") {
        try await withTemporaryDirectory(prefix: "Playback") { root in
            let first = root.appendingPathComponent("first.wav")
            let second = root.appendingPathComponent("second.wav")
            try writeReviewSilence(to: first)
            try writeReviewSilence(to: second)
            let player = RecordingAudioPlayerModel()
            await player.load(url: first)
            player.seek(to: 3)
            await player.load(url: second)
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(player.currentTime, 0)
            try expect(!player.isPlaying && player.canSeek)
            await player.load(url: root.appendingPathComponent("missing.wav"))
            player.seek(to: 1)
            player.togglePlayback()
            try expect(!player.canSeek && !player.isPlaying && player.errorMessage != nil)
            player.suspend()
        }
    }
}

@MainActor
private func waitForPlayback(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        if ContinuousClock.now >= deadline { throw TestFailure(description: "Timed out waiting for playback state") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func writeReviewSilence(to url: URL) throws {
    let sampleRate = 8_000
    let bytes = sampleRate * 4 * 2
    var data = Data()
    func ascii(_ string: String) { data.append(contentsOf: string.utf8) }
    func integer<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    ascii("RIFF"); integer(UInt32(36 + bytes)); ascii("WAVEfmt ")
    integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
    integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 2)); integer(UInt16(2)); integer(UInt16(16))
    ascii("data"); integer(UInt32(bytes)); data.append(Data(count: bytes))
    try data.write(to: url)
}
