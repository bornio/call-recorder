@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
@testable import CallRecorderCore

func runAudioExportServiceTests() throws {
    try runTest("publication destinations respect paths reserved by queued recordings") {
        let service = AudioExportService()
        let root = URL(fileURLWithPath: "/tmp/call-recorder-output", isDirectory: true)
        var first = RecordingManifest(
            createdAt: Date(timeIntervalSince1970: 1_752_654_600),
            language: .english,
            microphoneUID: "mic",
            microphoneName: "Mic"
        )
        first.captureStartedAt = first.createdAt
        first.timeZoneIdentifier = "UTC"
        let firstPath = service.publicationDirectory(for: first, in: root)

        var second = first
        second.id = UUID()
        let secondPath = service.publicationDirectory(
            for: second,
            in: root,
            reservedPaths: [firstPath.path]
        )

        try expectEqual(secondPath.lastPathComponent, "2025-07-16 08-30 — Call (2)")
        try expect(firstPath != secondPath)
    }

    try runTest("a finalized WAV publishes as a compact validated stereo M4A") {
        try withAudioExportTemporaryDirectory { root in
            let waveURL = root.appendingPathComponent("audio.wav")
            try writeStereoWave(to: waveURL, seconds: 2)

            var recording = RecordingManifest(
                createdAt: Date(timeIntervalSince1970: 1_720_600_200),
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            recording.captureStartedAt = Date(timeIntervalSince1970: 1_720_600_200)
            recording.captureEndedAt = Date(timeIntervalSince1970: 1_720_600_202)
            recording.timeZoneIdentifier = "Asia/Jerusalem"
            let exportRoot = root.appendingPathComponent("exports", isDirectory: true)

            let exportService = AudioExportService()
            let plannedDirectory = exportService.publicationDirectory(
                for: recording,
                in: exportRoot
            )
            let published = try exportService.publish(
                waveURL: waveURL,
                recording: recording,
                exportRoot: exportRoot,
                destinationDirectory: plannedDirectory
            )

            try expectEqual(published.audioURL.lastPathComponent, "Audio.m4a")
            try expectEqual(
                published.directoryURL.lastPathComponent,
                "2024-07-10 11-30 — Call"
            )
            try expect(abs(published.durationSeconds - 2) < 0.05)
            let publicFiles = try FileManager.default.contentsOfDirectory(
                at: published.directoryURL,
                includingPropertiesForKeys: nil
            )
            try expectEqual(publicFiles.map(\.lastPathComponent), ["Audio.m4a"])
            let compressed = try AVAudioFile(forReading: published.audioURL)
            try expectEqual(compressed.processingFormat.channelCount, 2)
            let waveSize = try require(
                try waveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
            let compressedSize = try require(
                try published.audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
            try expect(compressedSize < waveSize)

            let recovered = try AudioExportService().recoverPublication(
                in: published.directoryURL
            )
            try expectEqual(recovered.audioURL, published.audioURL)
            try expect(abs(recovered.durationSeconds - published.durationSeconds) < 0.001)

            var interrupted = recording
            interrupted.captureStatus = .processing
            interrupted.files.exportDirectory = published.directoryURL.path
            interrupted.files.audio = nil
            let postProcessed = try RecordingPostProcessor().process(
                recording: interrupted,
                store: RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            )
            try expectEqual(postProcessed.publication.audioURL, published.audioURL)
            try expectEqual(postProcessed.warnings, [])

            let collision = try AudioExportService().publish(
                waveURL: waveURL,
                recording: recording,
                exportRoot: exportRoot
            )
            try expect(collision.directoryURL.lastPathComponent.hasSuffix("(2)"))
        }
    }
}

private func writeStereoWave(to url: URL, seconds: Int) throws {
    let format = try require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )
    )
    let frameCount = AVAudioFrameCount(48_000 * seconds)
    do {
        let fileSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let phase = Float(frame) / 48_000 * 440 * 2 * .pi
            buffer.floatChannelData?[0][frame] = sin(phase) * 0.25
            buffer.floatChannelData?[1][frame] = sin(phase * 0.75) * 0.25
        }
        try file.write(from: buffer)
    }
}

private func withAudioExportTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CallRecorderAudioExportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}
