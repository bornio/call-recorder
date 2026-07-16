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
            try writeClosedCaptureMetadata(for: recording, store: store)

            let recovered = try store.recoverInterruptedRecordings(
                now: Date(timeIntervalSince1970: 500)
            )
            try expectEqual(recovered.first?.captureStatus, .processing)
            try expectEqual(recovered.first?.lastFailure?.stage, .finalization)
            try expect(FileManager.default.fileExists(atPath: chunk.path))
        }
    }

    try runTest("crash before capture starts does not create ghost recovery history") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            try expect(recording.captureStartedAt == nil)

            let recovered = try store.recoverInterruptedRecordings()

            try expectEqual(recovered, [])
            try expectEqual(try store.loadAll(), [])
        }
    }

    try runTest("started partial capture is retained when only one channel can recover") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            recording.captureStartedAt = Date(timeIntervalSince1970: 100)
            try store.save(recording)
            let systemChunk = try store.url(
                for: "capture/system/closed.caf",
                in: recording
            )
            try Data([1, 2, 3]).write(to: systemChunk)
            let metadata = Data(
                "{\"file\":\"closed.caf\",\"firstHostTime\":1,\"lastHostTime\":1,\"lastFrames\":1,\"frames\":1,\"sampleRate\":48000}\n".utf8
            )
            try metadata.write(to: try store.url(
                for: "capture/system/chunks.jsonl",
                in: recording
            ))

            let recovered = try store.recoverInterruptedRecordings(
                now: Date(timeIntervalSince1970: 500)
            )

            try expectEqual(recovered.first?.captureStatus, .failed)
            try expectEqual(recovered.first?.transcriptionStatus, .failed)
            try expectEqual(recovered.first?.lastFailure?.stage, .capture)
            try expect(FileManager.default.fileExists(atPath: systemChunk.path))
            try expectEqual(try store.loadAll().first?.id, recording.id)
        }
    }

    try runTest("interrupted transcription without a saved response requires manual retry") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            recording.captureStatus = .complete
            recording.transcriptionStatus = .transcribing
            try store.save(recording)

            let recovered = try store.recoverInterruptedRecordings()

            try expectEqual(recovered.first?.transcriptionStatus, .failed)
            try expectEqual(recovered.first?.lastFailure?.stage, .transcription)
            try expect(recovered.first?.lastFailure?.message.contains("may already") == true)
        }
    }

    try runTest("interrupted transcription with a saved response resumes locally") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            recording.captureStatus = .complete
            recording.transcriptionStatus = .transcribing
            try store.save(recording)
            let response = Data(
                "{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"Hi\",\"words\":[]}]}]}}".utf8
            )
            try response.write(
                to: try store.directory(for: recording).appendingPathComponent("transcript.json")
            )

            let recovered = try require(try store.recoverInterruptedRecordings().first)

            try expectEqual(recovered.transcriptionStatus, .notStarted)
            try expectEqual(recovered.files.transcriptJSON, "transcript.json")
            try expect(recovered.lastFailure == nil)
            try expect(recovered.warnings.first?.contains("without another upload") == true)
        }
    }

    try runTest("recovery preserves a capture failure while resuming finalization") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            recording.captureStatus = .processing
            recording.lastFailure = RecordingFailure(
                stage: .capture,
                message: "The output device changed during recording."
            )
            try store.save(recording)

            let recovered = try require(try store.recoverInterruptedRecordings().first)

            try expectEqual(recovered.captureStatus, .processing)
            try expectEqual(recovered.lastFailure?.stage, .capture)
            try expectEqual(
                recovered.lastFailure?.message,
                "The output device changed during recording."
            )
            try expectEqual(
                recovered.warnings,
                ["Finalization was interrupted and will resume."]
            )
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
            try writeClosedCaptureMetadata(for: recording, store: store)
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
            try expect(FinalizationRecoveryPolicy.canRecover(
                reconciled[0],
                hasRecoverableCapture: store.hasClosedCaptureMetadata(for: reconciled[0])
            ))
            try FileManager.default.removeItem(
                at: try store.url(for: "capture/microphone/closed.caf", in: reconciled[0])
            )
            try expect(!store.hasClosedCaptureMetadata(for: reconciled[0]))
        }
    }

    try runTest("a damaged manifest remains visible without offering false recovery") {
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
            try expect(!FinalizationRecoveryPolicy.canRecover(
                loaded[0],
                hasRecoverableCapture: store.hasClosedCaptureMetadata(for: loaded[0])
            ))
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
            try expectEqual(reconciled.transcriptionStatus, .failed)
            try expectEqual(reconciled.lastFailure?.stage, .transcription)
            try expectEqual(
                reconciled.files.transcriptMarkdown,
                movedFolder.appendingPathComponent("Transcript.md").path
            )

            try FileManager.default.removeItem(at: movedFolder.appendingPathComponent("Audio.m4a"))
            let remaining = try store.reconcileExternalFiles()
            try expect(remaining.isEmpty)
        }
    }

    try runTest("discard intent hides damaged history and is purged on recovery") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let chunk = try store.url(for: "capture/system/closed.caf", in: recording)
            try Data(repeating: 1, count: 32).write(to: chunk)
            try store.markDiscardRequested(for: recording)
            try Data("damaged".utf8).write(
                to: try store.directory(for: recording).appendingPathComponent("manifest.json")
            )

            try expectEqual(try store.loadAll(), [])
            let usageBeforePurge = try store.storageUsage()
            try expect(
                usageBeforePurge.privateHistoryBytes > 0,
                "Private usage was \(usageBeforePurge.privateHistoryBytes)"
            )
            try expect(
                usageBeforePurge.recoveryBytes >= 32,
                "Recovery usage was \(usageBeforePurge.recoveryBytes)"
            )

            _ = try store.recoverInterruptedRecordings()

            try expectEqual(try store.loadAll(), [])
            try expectEqual(try store.storageUsage(), .zero)
        }
    }

    try runTest("a resolved Trash bookmark never falls back to a reused stored path") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let goodDirectory = root.appendingPathComponent("Exports", isDirectory: true)
            let trashDirectory = root.appendingPathComponent(".Trash/Call", isDirectory: true)
            try FileManager.default.createDirectory(at: goodDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let goodAudio = goodDirectory.appendingPathComponent("Audio.m4a")
            let trashedAudio = trashDirectory.appendingPathComponent("Audio.m4a")
            try Data([1]).write(to: goodAudio)
            try Data([2]).write(to: trashedAudio)
            recording.files.audio = goodAudio.path
            recording.files.audioBookmark = try store.bookmark(for: trashedAudio)
            try store.save(recording)

            let trashedResolution = try store.audioURL(for: recording)
            try expect(trashedResolution == nil)

            recording.files.audioBookmark = Data("not a bookmark".utf8)
            let unresolvedBookmark = try store.audioURL(for: recording)
            try expect(unresolvedBookmark == nil)
            recording.files.audioBookmark = nil
            try expectEqual(try store.audioURL(for: recording), goodAudio)
        }
    }

    try runTest("audio-first then transcript deletion removes private history") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let publicDirectory = root.appendingPathComponent("Call", isDirectory: true)
            try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
            let audio = publicDirectory.appendingPathComponent("Audio.m4a")
            let transcript = publicDirectory.appendingPathComponent("Transcript.md")
            try Data([1]).write(to: audio)
            try Data("text".utf8).write(to: transcript)
            recording.captureStatus = .complete
            recording.transcriptionStatus = .complete
            recording.files.audio = audio.path
            recording.files.audioBookmark = try store.bookmark(for: audio)
            recording.files.transcriptMarkdown = transcript.path
            recording.files.transcriptBookmark = try store.bookmark(for: transcript)
            try store.save(recording)

            try FileManager.default.removeItem(at: audio)
            let transcriptOnly = try require(try store.reconcileExternalFiles().first)
            try expect(transcriptOnly.files.audio == nil)
            try expectEqual(transcriptOnly.files.transcriptMarkdown, transcript.path)

            try FileManager.default.removeItem(at: transcript)
            try expectEqual(try store.reconcileExternalFiles(), [])
        }
    }

    try runTest("unavailable imported volume preserves private history") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "",
                microphoneName: "Imported audio"
            )
            recording.origin = .importedAudio
            recording.captureStatus = .complete
            recording.files.audio = "/Volumes/CallRecorderMissingVolume/meeting.m4a"
            try store.save(recording)

            let reconciled = try store.reconcileExternalFiles()

            try expectEqual(reconciled.map(\.id), [recording.id])
            try expectEqual(reconciled[0].files.audio, recording.files.audio)
        }
    }

    try runTest("planned transcript path is not adopted without provenance") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let publicDirectory = root.appendingPathComponent("Call", isDirectory: true)
            try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
            let audio = publicDirectory.appendingPathComponent("Audio.m4a")
            let plannedTranscript = publicDirectory.appendingPathComponent("Transcript.md")
            try Data([1]).write(to: audio)
            try Data("someone else's file".utf8).write(to: plannedTranscript)
            recording.captureStatus = .complete
            recording.transcriptionStatus = .notStarted
            recording.files.audio = audio.path
            recording.files.audioBookmark = try store.bookmark(for: audio)
            recording.files.transcriptMarkdown = plannedTranscript.path
            try store.save(recording)
            let response = Data(
                "{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"Hi\",\"words\":[]}]}]}}".utf8
            )
            try response.write(
                to: try store.directory(for: recording).appendingPathComponent("transcript.json")
            )

            let reconciled = try require(try store.reconcileExternalFiles().first)

            try expectEqual(reconciled.transcriptionStatus, .notStarted)
            try expect(reconciled.files.transcriptBookmark == nil)
            try expectEqual(
                try String(contentsOf: plannedTranscript, encoding: .utf8),
                "someone else's file"
            )
        }
    }

    try runTest("storage accounting and forgetting history leave exports untouched") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            let recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let chunk = try store.url(for: "capture/microphone/closed.caf", in: recording)
            try Data(repeating: 3, count: 128).write(to: chunk)
            try Data(repeating: 4, count: 64).write(
                to: try store.directory(for: recording).appendingPathComponent("transcript.json")
            )
            let export = root.appendingPathComponent("Call/Audio.m4a")
            try FileManager.default.createDirectory(
                at: export.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 5, count: 256).write(to: export)

            let usage = try store.storageUsage()
            try expect(usage.privateHistoryBytes >= 192)
            try expectEqual(usage.recoveryBytesByRecordingID[recording.id], 128)

            try store.forgetAllHistory()

            try expect(FileManager.default.fileExists(atPath: export.path))
            try expectEqual(try store.storageUsage(), .zero)
        }
    }

    try runTest("stale private cleanup is exact age checked and does not follow symlinks") {
        try withTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            let recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let directory = try store.directory(for: recording)
            let stale = directory.appendingPathComponent(".audio.wav.partial")
            let fresh = directory.appendingPathComponent("capture/.system-aligned.raw")
            let unrelated = directory.appendingPathComponent("capture/keep.partial")
            let external = root.appendingPathComponent("external.raw")
            let symlink = directory.appendingPathComponent("capture/system/.microphone-aligned.raw")
            try Data([1]).write(to: stale)
            try Data([2]).write(to: fresh)
            try Data([3]).write(to: unrelated)
            try Data([4]).write(to: external)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
            let oldDate = Date(timeIntervalSince1970: 100)
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: stale.path
            )
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: unrelated.path
            )

            try store.cleanupStalePrivateArtifacts(
                olderThan: Date(timeIntervalSince1970: 200)
            )

            try expect(!FileManager.default.fileExists(atPath: stale.path))
            try expect(FileManager.default.fileExists(atPath: fresh.path))
            try expect(FileManager.default.fileExists(atPath: unrelated.path))
            try expect(FileManager.default.fileExists(atPath: symlink.path))
            try expect(FileManager.default.fileExists(atPath: external.path))
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

private func writeClosedCaptureMetadata(
    for recording: RecordingManifest,
    store: RecordingStore
) throws {
    let metadata = Data(
        "{\"file\":\"closed.caf\",\"firstHostTime\":1,\"lastHostTime\":1,\"lastFrames\":1,\"frames\":1,\"sampleRate\":48000}\n".utf8
    )
    for relativePath in [
        "capture/system/chunks.jsonl",
        "capture/microphone/chunks.jsonl",
    ] {
        try metadata.write(to: try store.url(for: relativePath, in: recording))
    }
    for relativePath in [
        "capture/system/closed.caf",
        "capture/microphone/closed.caf",
    ] where !FileManager.default.fileExists(
        atPath: try store.url(for: relativePath, in: recording).path
    ) {
        try Data([1]).write(to: try store.url(for: relativePath, in: recording))
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CallRecorderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}
