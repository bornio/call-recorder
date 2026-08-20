@preconcurrency import AVFoundation
import Foundation
@testable import CallRecorderCore

@MainActor
func runAudioExportServiceTests() async throws {
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

    try await runAsyncTest("a finalized WAV publishes, recovers, and avoids collisions") {
        try await withTemporaryDirectory(prefix: "CallRecorderAudioExportTests") { root in
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
            recording.title = "Product roadmap review"
            recording.titleSource = .user
            recording.assignMeeting(
                CalendarEventCandidate(
                    identifier: "event-123",
                    title: "Roadmap calendar event",
                    startDate: Date(timeIntervalSince1970: 1_720_600_000),
                    endDate: Date(timeIntervalSince1970: 1_720_603_600),
                    attendeeNames: ["Private attendee"]
                ),
                state: .manual,
                updateCalendarTitle: false
            )
            let exportRoot = root.appendingPathComponent("exports", isDirectory: true)

            let exportService = AudioExportService()
            let plannedDirectory = exportService.publicationDirectory(
                for: recording,
                in: exportRoot
            )
            let published = try await exportService.publish(
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
            try expectEqual(
                publicFiles.map(\.lastPathComponent).sorted(),
                ["Audio.m4a", "Transcript.md"]
            )
            let placeholder = try String(
                contentsOf: published.directoryURL.appendingPathComponent("Transcript.md"),
                encoding: .utf8
            )
            try expect(placeholder.contains("title: \"Product roadmap review\""))
            try expect(placeholder.contains("transcription_status: pending"))
            try expect(placeholder.contains("meeting_association: manual"))
            try expect(placeholder.contains("calendar_event_id: \"event-123\""))
            try expect(placeholder.contains("calendar_started_at:"))
            try expect(!placeholder.contains("Private attendee"))
            let compressed = try AVAudioFile(forReading: published.audioURL)
            try expectEqual(compressed.processingFormat.channelCount, 2)
            let audioMetadata = try await audioMetadata(at: published.audioURL)
            try expectEqual(
                audioMetadata[AVMetadataIdentifier.iTunesMetadataSongName.rawValue],
                "Product roadmap review"
            )
            try expectEqual(
                audioMetadata[AVMetadataIdentifier.iTunesMetadataReleaseDate.rawValue],
                "2024-07-10T08:30:00.000Z"
            )
            try expectEqual(
                audioMetadata[AVMetadataIdentifier.iTunesMetadataUserComment.rawValue],
                "Recording ID: \(recording.id.uuidString)"
            )
            try expectEqual(
                audioMetadata[AVMetadataIdentifier.iTunesMetadataEncodingTool.rawValue],
                "Call Recorder"
            )
            try expectEqual(published.warnings, [])

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
            try expectThrows(
                AudioExportError.self,
                matching: {
                    if case .publicationDoesNotBelongToRecording = $0 { return true }
                    return false
                }
            ) {
                try AudioExportService().recoverPublication(
                    in: published.directoryURL,
                    recordingID: UUID()
                )
            }

            var interrupted = recording
            interrupted.captureStatus = .processing
            interrupted.files.exportDirectory = published.directoryURL.path
            interrupted.files.audio = nil
            let postProcessed = try await RecordingPostProcessor().process(
                recording: interrupted,
                store: RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            )
            try expectEqual(postProcessed.publication.audioURL, published.audioURL)
            try expectEqual(postProcessed.warnings, [])

            let collision = try await AudioExportService().publish(
                waveURL: waveURL,
                recording: recording,
                exportRoot: exportRoot
            )
            try expect(collision.directoryURL.lastPathComponent.hasSuffix("(2)"))
        }
    }

    try await runAsyncTest("unrelated audio is never accepted as an interrupted publication") {
        try await withTemporaryDirectory(prefix: "CallRecorderAudioExportTests") { root in
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

            try await expectThrows(
                AudioExportError.self,
                matching: {
                    if case .publicationDoesNotBelongToRecording = $0 { return true }
                    return false
                }
            ) {
                try await RecordingPostProcessor().process(
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
        try withTemporaryDirectory(prefix: "CallRecorderAudioExportTests") { root in
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

private func audioMetadata(at url: URL) async throws -> [String: String] {
    let asset = AVURLAsset(url: url)
    let formats = try await asset.load(.availableMetadataFormats)
    var metadata: [String: String] = [:]
    for format in formats {
        for item in try await asset.loadMetadata(for: format) {
            guard let identifier = item.identifier,
                  let value = try await item.load(.stringValue)
            else { continue }
            metadata[identifier.rawValue] = value
        }
    }
    return metadata
}
