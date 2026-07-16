import Foundation
@testable import CallRecorderCore

func runRecordingJobQueueTests() async throws {
    try await runAsyncTest("capture blocks queued transcription until capture ends") {
        try await withQueueTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let recording = try queuedTranscriptionRecording(in: store, root: root)
            let transcribed = AsyncSignal()
            let queue = await RecordingJobQueue(
                store: store,
                apiKeyProvider: { "test-key" },
                finalize: { _, _ in
                    throw TestFailure(description: "Unexpected finalization")
                },
                transcribe: { original, store, _ in
                    var updated = try store.load(id: original.id)
                    updated.transcriptionStatus = .complete
                    try store.save(updated)
                    await transcribed.signal()
                    return updated
                }
            )

            await queue.wake()
            try expectEqual(try store.load(id: recording.id).transcriptionStatus, .notStarted)

            await queue.captureDidEnd()
            await transcribed.wait()

            try expectEqual(try store.load(id: recording.id).transcriptionStatus, .complete)
            await queue.shutdownImmediately()
        }
    }

    try await runAsyncTest("local transcript recovery never asks for a Deepgram key") {
        try await withQueueTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            let recording = try queuedTranscriptionRecording(in: store, root: root)
            let response = Data(
                "{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\"Hi\",\"words\":[]}]}]}}".utf8
            )
            try response.write(
                to: try store.directory(for: recording).appendingPathComponent("transcript.json")
            )
            let providerCalls = SynchronousCounter()
            let completed = AsyncSignal()
            let queue = await RecordingJobQueue(
                store: store,
                apiKeyProvider: {
                    providerCalls.increment()
                    return nil
                },
                finalize: { _, _ in
                    throw TestFailure(description: "Unexpected finalization")
                },
                transcribe: { original, store, apiKey in
                    try expectEqual(apiKey, "")
                    var updated = try store.load(id: original.id)
                    updated.transcriptionStatus = .complete
                    try store.save(updated)
                    await completed.signal()
                    return updated
                }
            )

            await queue.start()
            await completed.wait()

            try expectEqual(providerCalls.value, 0)
            try expectEqual(try store.load(id: recording.id).transcriptionStatus, .complete)
            await queue.shutdownImmediately()
        }
    }

    try await runAsyncTest("active transcription finishes during capture while new work waits") {
        try await withQueueTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let first = try queuedTranscriptionRecording(in: store, root: root)
            let started = AsyncSignal()
            let allowCompletion = AsyncSignal()
            let firstCompleted = AsyncSignal()
            let secondCompleted = AsyncSignal()
            let queue = await RecordingJobQueue(
                store: store,
                apiKeyProvider: { "test-key" },
                finalize: { _, _ in
                    throw TestFailure(description: "Unexpected finalization")
                },
                transcribe: { original, store, _ in
                    var recording = try store.load(id: original.id)
                    recording.transcriptionStatus = .transcribing
                    try store.save(recording)
                    if original.id == first.id {
                        await started.signal()
                        await allowCompletion.wait()
                    }
                    recording.transcriptionStatus = .complete
                    try store.save(recording)
                    if original.id == first.id {
                        await firstCompleted.signal()
                    } else {
                        await secondCompleted.signal()
                    }
                    return recording
                }
            )

            await queue.start()
            await started.wait()
            await queue.suspendNewWork()
            let second = try queuedTranscriptionRecording(
                in: store,
                root: root,
                folderName: "Call 2"
            )
            await allowCompletion.signal()
            await firstCompleted.wait()

            try expectEqual(try store.load(id: first.id).transcriptionStatus, .complete)
            try expectEqual(try store.load(id: second.id).transcriptionStatus, .notStarted)

            await queue.captureDidEnd()
            await secondCompleted.wait()
            try expectEqual(try store.load(id: second.id).transcriptionStatus, .complete)
            await queue.shutdownImmediately()
        }
    }

    try await runAsyncTest("unexpected cancellation during capture fails without retrying") {
        try await withQueueTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            let recording = try queuedTranscriptionRecording(in: store, root: root)
            let attempts = AsyncCounter()
            let started = AsyncSignal()
            let cancelRequest = AsyncSignal()
            let firstRunFinished = AsyncSignal()
            let postCaptureRunFinished = AsyncSignal()
            let queue = await RecordingJobQueue(
                store: store,
                apiKeyProvider: { "test-key" },
                finalize: { _, _ in
                    throw TestFailure(description: "Unexpected finalization")
                },
                transcribe: { original, store, _ in
                    await attempts.increment()
                    var active = try store.load(id: original.id)
                    active.transcriptionStatus = .transcribing
                    try store.save(active)
                    await started.signal()
                    await cancelRequest.wait()
                    var queued = try store.load(id: original.id)
                    queued.transcriptionStatus = .notStarted
                    queued.lastFailure = nil
                    try store.save(queued)
                    throw CancellationError()
                }
            )
            await MainActor.run {
                queue.onChange = { activity in
                    if activity == nil {
                        Task { await firstRunFinished.signal() }
                    }
                }
            }

            await queue.start()
            await started.wait()
            await queue.suspendNewWork()
            await cancelRequest.signal()
            await firstRunFinished.wait()

            var failed = try store.load(id: recording.id)
            try expectEqual(failed.transcriptionStatus, .failed)
            try expectEqual(failed.lastFailure?.stage, .transcription)

            await MainActor.run {
                queue.onChange = { activity in
                    if activity == nil {
                        Task { await postCaptureRunFinished.signal() }
                    }
                }
            }
            await queue.captureDidEnd()
            await postCaptureRunFinished.wait()

            failed = try store.load(id: recording.id)
            let attemptCount = await attempts.value
            try expectEqual(failed.transcriptionStatus, .failed)
            try expectEqual(attemptCount, 1)
            await queue.shutdownImmediately()
        }
    }

    try await runAsyncTest("active finalization finishes during capture without starting transcription") {
        try await withQueueTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let output = root.appendingPathComponent("Call", isDirectory: true)
            recording.captureStatus = .processing
            recording.files.exportDirectory = output.path
            recording.files.transcriptMarkdown = output.appendingPathComponent("Transcript.md").path
            try store.save(recording)
            let recordingID = recording.id

            let finalizationStarted = AsyncSignal()
            let allowFinalization = AsyncSignal()
            let finalizationPersisted = AsyncSignal()
            let transcriptionCompleted = AsyncSignal()
            let publication = PublishedRecordingAudio(
                directoryURL: output,
                audioURL: output.appendingPathComponent("Audio.m4a"),
                durationSeconds: 12
            )
            let queue = await RecordingJobQueue(
                store: store,
                apiKeyProvider: { "test-key" },
                finalize: { _, _ in
                    await finalizationStarted.signal()
                    await allowFinalization.wait()
                    return RecordingPostProcessingResult(
                        publication: publication,
                        warnings: []
                    )
                },
                transcribe: { original, store, _ in
                    var updated = try store.load(id: original.id)
                    updated.transcriptionStatus = .complete
                    try store.save(updated)
                    await transcriptionCompleted.signal()
                    return updated
                }
            )
            await MainActor.run {
                queue.onChange = { _ in
                    if (try? store.load(id: recordingID).captureStatus) == .complete {
                        Task { await finalizationPersisted.signal() }
                    }
                }
            }

            await queue.start()
            await finalizationStarted.wait()
            await queue.suspendNewWork()
            await allowFinalization.signal()
            await finalizationPersisted.wait()

            try expectEqual(try store.load(id: recordingID).transcriptionStatus, .notStarted)
            await queue.captureDidEnd()
            await transcriptionCompleted.wait()
            try expectEqual(try store.load(id: recordingID).transcriptionStatus, .complete)
            await queue.shutdownImmediately()
        }
    }

    try await runAsyncTest("crash recovery finalizes and remains eligible for transcription") {
        try await withQueueTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            let recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let chunk = try store.url(for: "capture/system/closed.caf", in: recording)
            try Data([1, 2, 3]).write(to: chunk)
            try writeQueueClosedCapture(for: recording, store: store)
            _ = try store.recoverInterruptedRecordings()

            let output = root.appendingPathComponent("Recovered Call", isDirectory: true)
            let audio = output.appendingPathComponent("Audio.m4a")
            let transcribed = AsyncSignal()
            let queue = await RecordingJobQueue(
                store: store,
                apiKeyProvider: { "test-key" },
                finalize: { _, _ in
                    try FileManager.default.createDirectory(
                        at: output,
                        withIntermediateDirectories: true
                    )
                    try Data([0, 1, 2, 3]).write(to: audio)
                    return RecordingPostProcessingResult(
                        publication: PublishedRecordingAudio(
                            directoryURL: output,
                            audioURL: audio,
                            durationSeconds: 8
                        ),
                        warnings: []
                    )
                },
                transcribe: { original, store, _ in
                    var updated = try store.load(id: original.id)
                    updated.transcriptionStatus = .complete
                    try store.save(updated)
                    await transcribed.signal()
                    return updated
                }
            )

            await queue.start()
            await transcribed.wait()

            let recovered = try store.load(id: recording.id)
            try expectEqual(recovered.captureStatus, .complete)
            try expectEqual(recovered.transcriptionStatus, .complete)
            try expect(recovered.lastFailure == nil)
            await queue.shutdownImmediately()
        }
    }

    try await runAsyncTest("failed work is attempted once per queue run") {
        try await withQueueTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root)
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            recording.captureStatus = .complete
            recording.files.audio = root.appendingPathComponent("missing.m4a").path
            try store.save(recording)
            let attempts = AsyncCounter()
            let runnerFinished = AsyncSignal()
            let transcriptionService = TranscriptionService(
                client: DeepgramClient { _, _ in
                    throw TestFailure(description: "Unexpected upload")
                }
            )
            let queue = await RecordingJobQueue(
                store: store,
                apiKeyProvider: { "test-key" },
                finalize: { _, _ in
                    throw TestFailure(description: "Unexpected finalization")
                },
                transcribe: { recording, store, apiKey in
                    await attempts.increment()
                    return try await transcriptionService.transcribe(
                        recording: recording,
                        store: store,
                        apiKey: apiKey
                    )
                }
            )
            await MainActor.run {
                queue.onChange = { activity in
                    if activity == nil {
                        Task { await runnerFinished.signal() }
                    }
                }
            }

            await queue.start()
            await runnerFinished.wait()

            try expectEqual(await attempts.value, 1)
            let failed = try store.load(id: recording.id)
            try expectEqual(failed.transcriptionStatus, .failed)
            try expectEqual(failed.lastFailure?.stage, .transcription)
            await queue.shutdownImmediately()
        }
    }

    try await runAsyncTest("finalization retry preserves a genuine capture failure") {
        try await withQueueTemporaryDirectory { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
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
            _ = try store.recoverInterruptedRecordings()

            let output = root.appendingPathComponent("Partial Call", isDirectory: true)
            let audio = output.appendingPathComponent("Audio.m4a")
            let finalizationAttempts = AsyncCounter()
            let transcriptionAttempts = AsyncCounter()
            let firstRunFinished = AsyncSignal()
            let secondRunFinished = AsyncSignal()
            let queue = await RecordingJobQueue(
                store: store,
                apiKeyProvider: { "test-key" },
                finalize: { _, _ in
                    if await finalizationAttempts.incrementAndGet() == 1 {
                        throw TestFailure(description: "Encoding failed")
                    }
                    try FileManager.default.createDirectory(
                        at: output,
                        withIntermediateDirectories: true
                    )
                    try Data([0, 1, 2, 3]).write(to: audio)
                    return RecordingPostProcessingResult(
                        publication: PublishedRecordingAudio(
                            directoryURL: output,
                            audioURL: audio,
                            durationSeconds: 5
                        ),
                        warnings: []
                    )
                },
                transcribe: { recording, _, _ in
                    await transcriptionAttempts.increment()
                    return recording
                }
            )
            await MainActor.run {
                queue.onChange = { activity in
                    if activity == nil {
                        Task { await firstRunFinished.signal() }
                    }
                }
            }

            await queue.start()
            await firstRunFinished.wait()

            var partial = try store.load(id: recording.id)
            try expectEqual(partial.captureStatus, .failed)
            try expectEqual(partial.lastFailure?.stage, .capture)
            try expect(partial.files.audio == nil)
            try expect(FinalizationRecoveryPolicy.canRecover(
                partial,
                hasRecoverableCapture: true
            ))
            try expect(
                partial.warnings.contains { $0.hasPrefix("Audio finalization failed:") }
            )

            partial.captureStatus = .processing
            try store.save(partial)
            await MainActor.run {
                queue.onChange = { activity in
                    if activity == nil {
                        Task { await secondRunFinished.signal() }
                    }
                }
            }
            await queue.wake()
            await secondRunFinished.wait()

            partial = try store.load(id: recording.id)
            let transcriptionAttemptCount = await transcriptionAttempts.value
            let finalizationAttemptCount = await finalizationAttempts.value
            try expectEqual(partial.captureStatus, .failed)
            try expectEqual(partial.lastFailure?.stage, .capture)
            try expectEqual(partial.files.audio, audio.path)
            try expectEqual(transcriptionAttemptCount, 0)
            try expectEqual(finalizationAttemptCount, 2)
            await queue.shutdownImmediately()
        }
    }
}

private actor AsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }

    func incrementAndGet() -> Int {
        value += 1
        return value
    }
}

private final class SynchronousCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private func queuedTranscriptionRecording(
    in store: RecordingStore,
    root: URL,
    folderName: String = "Call"
) throws -> RecordingManifest {
    var recording = try store.createRecording(
        language: .english,
        microphoneUID: "mic",
        microphoneName: "Mic"
    )
    let output = root.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let audio = output.appendingPathComponent("Audio.m4a")
    try Data([0, 1, 2, 3]).write(to: audio)
    recording.captureStatus = .complete
    recording.transcriptionStatus = .notStarted
    recording.files.exportDirectory = output.path
    recording.files.audio = audio.path
    recording.files.transcriptMarkdown = output.appendingPathComponent("Transcript.md").path
    try store.save(recording)
    return recording
}

private func writeQueueClosedCapture(
    for recording: RecordingManifest,
    store: RecordingStore
) throws {
    let metadata = Data(
        "{\"file\":\"closed.caf\",\"firstHostTime\":1,\"lastHostTime\":1,\"lastFrames\":1,\"frames\":1,\"sampleRate\":48000}\n".utf8
    )
    for source in ["system", "microphone"] {
        try metadata.write(
            to: try store.url(for: "capture/\(source)/chunks.jsonl", in: recording)
        )
        let chunk = try store.url(for: "capture/\(source)/closed.caf", in: recording)
        if !FileManager.default.fileExists(atPath: chunk.path) {
            try Data([1]).write(to: chunk)
        }
    }
}

private func withQueueTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CallRecorderQueueTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}
