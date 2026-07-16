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
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
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
                in: published.directoryURL,
                recordingID: recording.id
            )
            try expectEqual(recovered.audioURL, published.audioURL)
            try expect(abs(recovered.durationSeconds - published.durationSeconds) < 0.001)
            try expect(AudioExportService.publicationBelongs(
                in: published.directoryURL,
                to: recording.id
            ))
            try expect(!AudioExportService.publicationBelongs(
                in: published.directoryURL,
                to: UUID()
            ))
            try expectThrows {
                try AudioExportService().recoverPublication(
                    in: published.directoryURL,
                    recordingID: UUID()
                )
            }

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

    try runTest("unrelated audio is never accepted as an interrupted publication") {
        try withAudioExportTemporaryDirectory { root in
            let destination = root.appendingPathComponent("Call", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: destination.appendingPathComponent("Audio.m4a"))
            var recording = RecordingManifest(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            recording.captureStatus = .processing
            recording.files.exportDirectory = destination.path

            try expectThrows {
                try RecordingPostProcessor().process(
                    recording: recording,
                    store: RecordingStore(rootDirectory: root.appendingPathComponent("history"))
                )
            }
            try expect(
                FileManager.default.fileExists(
                    atPath: destination.appendingPathComponent("Audio.m4a").path
                )
            )
        }
    }

    try runTest("stale publication cleanup removes only exact partial artifacts") {
        try withAudioExportTemporaryDirectory { root in
            let staging = root.appendingPathComponent(
                ".call-recorder-\(UUID().uuidString).partial",
                isDirectory: true
            )
            let transcriptPartial = root.appendingPathComponent(
                ".call-recorder-Transcript.md.\(UUID().uuidString).partial"
            )
            let unrelated = root.appendingPathComponent("notes.partial")
            let genericMarkdownPartial = root.appendingPathComponent(
                ".Transcript.md.\(UUID().uuidString).partial"
            )
            let fresh = root.appendingPathComponent(
                ".call-recorder-\(UUID().uuidString).partial",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
            try Data([1]).write(to: transcriptPartial)
            try Data([2]).write(to: unrelated)
            try Data([3]).write(to: genericMarkdownPartial)
            let oldDate = Date(timeIntervalSince1970: 100)
            for url in [staging, transcriptPartial, unrelated, genericMarkdownPartial] {
                try FileManager.default.setAttributes(
                    [.modificationDate: oldDate],
                    ofItemAtPath: url.path
                )
            }

            try AudioExportService.cleanupStaleArtifacts(
                in: root,
                olderThan: Date(timeIntervalSince1970: 200)
            )

            try expect(!FileManager.default.fileExists(atPath: staging.path))
            try expect(!FileManager.default.fileExists(atPath: transcriptPartial.path))
            try expect(FileManager.default.fileExists(atPath: unrelated.path))
            try expect(FileManager.default.fileExists(atPath: genericMarkdownPartial.path))
            try expect(FileManager.default.fileExists(atPath: fresh.path))
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
