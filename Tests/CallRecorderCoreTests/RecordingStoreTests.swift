import Foundation
@testable import CallRecorderCore

func runRecordingStoreTests() throws {
    try runTest("manifest round-trips and history sorts newest first") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let older = try store.createRecording(
                language: .english,
                microphoneUID: "mic-a",
                microphoneName: "Mic A",
                now: Date(timeIntervalSince1970: 100),
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            )
            var newer = try store.createRecording(
                language: .hebrew,
                microphoneUID: "mic-b",
                microphoneName: "Mic B",
                localSpeakerName: "Taylor",
                keyterms: ["YeshID", "Decision Trace"],
                now: Date(timeIntervalSince1970: 200),
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            )
            newer.captureStatus = .complete
            newer.captureStartedAt = Date(timeIntervalSince1970: 200.125)
            newer.files.audio = "audio.wav"
            try store.save(newer)

            let loaded = try store.loadAll()
            try expectEqual(loaded.map(\.id), [newer.id, older.id])
            try expectEqual(loaded.first?.files.audio, "audio.wav")
            try expectEqual(loaded.first?.effectiveLocalSpeakerName, "Taylor")
            try expectEqual(loaded.first?.effectiveKeyterms, ["YeshID", "Decision Trace"])
            try expectEqual(loaded.last?.effectiveLocalSpeakerName, "Me")
            let loadedStart = try require(loaded.first?.captureStartedAt)
            try expect(abs(loadedStart.timeIntervalSince1970 - 200.125) < 0.001)
            let manifestURL = try store.directory(for: newer)
                .appendingPathComponent("manifest.json")
            try expect(FileManager.default.fileExists(atPath: manifestURL.path))
        }
    }

    try runTest("interrupted recording is queued for recovery while chunks remain") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let chunk = try store.url(for: "capture/system/closed.caf", in: recording)
            try Data([1, 2, 3]).write(to: chunk)

            let recovered = try store.recoverInterruptedRecordings(
                now: Date(timeIntervalSince1970: 500)
            )
            try expectEqual(recovered.first?.captureStatus, .processing)
            try expectEqual(recovered.first?.lastFailure?.stage, .capture)
            try expect(FileManager.default.fileExists(atPath: chunk.path))
        }
    }

    try runTest("manifest paths cannot escape recording directory") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            try expectThrows { try store.url(for: "../outside", in: recording) }

            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let link = try store.directory(for: recording)
                .appendingPathComponent("capture/system/link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            try expectThrows {
                try store.url(for: "capture/system/link/file.wav", in: recording)
            }
        }
    }

    try runTest("planned but unpublished recordings retain recovery material") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let chunk = try store.url(for: "capture/system/closed.caf", in: recording)
            try Data([1, 2, 3]).write(to: chunk)
            let plannedDirectory = root.appendingPathComponent("Planned Call", isDirectory: true)
            recording.captureStatus = .failed
            recording.lastFailure = RecordingFailure(
                stage: .finalization,
                message: "Encoding failed"
            )
            recording.files.exportDirectory = plannedDirectory.path
            recording.files.transcriptMarkdown = plannedDirectory
                .appendingPathComponent("Transcript.md").path
            try store.save(recording)

            let reconciled = try store.reconcileExternalFiles()

            try expectEqual(reconciled.map(\.id), [recording.id])
            try expect(FileManager.default.fileExists(atPath: chunk.path))
            try expect(FinalizationRecoveryPolicy.canRecover(reconciled[0]))
        }
    }

    try runTest("a damaged manifest remains visible and recoverable") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let recording = try store.createRecording(
                language: .hebrew,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let manifestURL = try store.directory(for: recording)
                .appendingPathComponent("manifest.json")
            try Data("not json".utf8).write(to: manifestURL)

            let loaded = try store.loadAll()

            try expectEqual(loaded.map(\.id), [recording.id])
            try expectEqual(loaded[0].captureStatus, .failed)
            try expectEqual(loaded[0].lastFailure?.stage, .finalization)
            try expect(FinalizationRecoveryPolicy.canRecover(loaded[0]))
        }
    }

    try runTest("Finder moves and deletions reconcile private history") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let originalFolder = root.appendingPathComponent("2026-07-10 10-30 — Call")
            try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
            let originalAudio = originalFolder.appendingPathComponent("Audio.m4a")
            let originalTranscript = originalFolder.appendingPathComponent("Transcript.md")
            try Data([1, 2, 3]).write(to: originalAudio)
            try Data("transcript".utf8).write(to: originalTranscript)

            recording.captureStatus = .complete
            recording.transcriptionStatus = .failed
            recording.lastFailure = RecordingFailure(
                stage: .transcription,
                message: "Interrupted after writing files"
            )
            recording.files.exportDirectory = originalFolder.path
            recording.files.audio = originalAudio.path
            recording.files.audioBookmark = try store.bookmark(for: originalAudio)
            recording.files.transcriptMarkdown = originalTranscript.path
            recording.files.transcriptBookmark = try store.bookmark(for: originalTranscript)
            try store.save(recording)
            let privateJSON = try store.directory(for: recording)
                .appendingPathComponent("transcript.json")
            try Data("{}".utf8).write(to: privateJSON)

            let movedFolder = root.appendingPathComponent("Renamed Call")
            try FileManager.default.moveItem(at: originalFolder, to: movedFolder)
            var reconciled = try require(try store.reconcileExternalFiles().first)
            try expectEqual(reconciled.files.audio, movedFolder.appendingPathComponent("Audio.m4a").path)
            try expectEqual(
                reconciled.files.transcriptMarkdown,
                movedFolder.appendingPathComponent("Transcript.md").path
            )
            try expectEqual(reconciled.transcriptionStatus, .complete)
            try expect(reconciled.lastFailure == nil)
            let captureDirectory = try store.directory(for: reconciled)
                .appendingPathComponent("capture")
            try expect(!FileManager.default.fileExists(atPath: captureDirectory.path))

            try FileManager.default.removeItem(
                at: movedFolder.appendingPathComponent("Transcript.md")
            )
            reconciled = try require(try store.reconcileExternalFiles().first)
            try expectEqual(reconciled.transcriptionStatus, .notStarted)
            try expectEqual(
                reconciled.files.transcriptMarkdown,
                movedFolder.appendingPathComponent("Transcript.md").path
            )

            try FileManager.default.removeItem(at: movedFolder.appendingPathComponent("Audio.m4a"))
            let remaining = try store.reconcileExternalFiles()
            try expect(remaining.isEmpty)
        }
    }

    try runTest("validated capture artifacts can be removed without deleting history") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let waveURL = try store.directory(for: recording).appendingPathComponent("audio.wav")
            try Data([1]).write(to: waveURL)

            try store.removeCaptureArtifacts(for: recording)

            try expect(!FileManager.default.fileExists(atPath: waveURL.path))
            try expectThrows {
                try store.url(for: "capture/system/new.caf", in: recording)
                    .checkResourceIsReachable()
            }
            try expectEqual(try store.loadAll().first?.id, recording.id)
        }
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CallRecorderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}
