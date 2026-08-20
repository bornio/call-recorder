@preconcurrency import AVFoundation
import CoreAudio
import Foundation
@testable import CallRecorderCore

@MainActor
func runRecordingFinalizerTests() async throws {
    try runTest("finalizer reads valid partial CAF reads through end of file") {
        try withTemporaryDirectory(prefix: "CallRecorderFinalizerTests") { root in
            let systemDirectory = root.appendingPathComponent("system", isDirectory: true)
            let microphoneDirectory = root.appendingPathComponent("microphone", isDirectory: true)
            try FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: microphoneDirectory, withIntermediateDirectories: true)

            let origin = AudioGetCurrentHostTime()
            let frames: AVAudioFrameCount = 720_384
            try writeChunk(
                directory: systemDirectory,
                filename: "000000.caf",
                sample: 0,
                frames: frames,
                firstHostTime: origin,
                tailSample: 0.75,
                tailFrames: 512
            )
            try writeChunk(
                directory: microphoneDirectory,
                filename: "000000.caf",
                sample: 0,
                frames: frames,
                firstHostTime: origin
            )

            let output = root.appendingPathComponent("audio.wav")
            let result = try RecordingFinalizer().finalize(
                recordingDirectory: root,
                systemCaptureDirectory: systemDirectory,
                microphoneCaptureDirectory: microphoneDirectory,
                outputURL: output
            )

            try expectEqual(result.warnings, [])
            let wav = try Data(contentsOf: output)
            let finalSystemSample = sample(in: wav, frame: Int(frames) - 1, channel: 0)
            try expect(abs(Double(finalSystemSample) / Double(Int16.max) - 0.75) < 0.01)
        }
    }

    try runTest("sources align into remote-left and local-microphone-right WAV channels") {
        try withTemporaryDirectory(prefix: "CallRecorderFinalizerTests") { root in
            let systemDirectory = root.appendingPathComponent("system", isDirectory: true)
            let microphoneDirectory = root.appendingPathComponent("microphone", isDirectory: true)
            try FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: microphoneDirectory, withIntermediateDirectories: true)

            let origin = AudioGetCurrentHostTime()
            try writeChunk(
                directory: systemDirectory,
                filename: "000000.caf",
                sample: 0.25,
                frames: 4_800,
                firstHostTime: origin
            )
            let microphoneStart = origin + AudioConvertNanosToHostTime(50_000_000)
            try writeChunk(
                directory: microphoneDirectory,
                filename: "000000.caf",
                sample: 0.5,
                frames: 2_400,
                firstHostTime: microphoneStart
            )
            let interruptedMetadata = try FileHandle(
                forWritingTo: systemDirectory.appendingPathComponent("chunks.jsonl")
            )
            try interruptedMetadata.seekToEnd()
            try interruptedMetadata.write(contentsOf: Data("{\"file\":".utf8))
            try interruptedMetadata.close()

            let output = root.appendingPathComponent("audio.wav")
            let result = try RecordingFinalizer().finalize(
                recordingDirectory: root,
                systemCaptureDirectory: systemDirectory,
                microphoneCaptureDirectory: microphoneDirectory,
                outputURL: output
            )
            try expect(abs(result.durationSeconds - 0.1) < 0.002)
            let wav = try Data(contentsOf: output)
            try expectEqual(Data(wav.prefix(4)), Data("RIFF".utf8))
            try expectEqual(wav.subdata(in: 8..<12), Data("WAVE".utf8))
            try expectEqual(wav.count, 44 + 4_800 * 4)

            let firstSystem = sample(in: wav, frame: 0, channel: 0)
            let firstMicrophone = sample(in: wav, frame: 0, channel: 1)
            let laterMicrophone = sample(in: wav, frame: 3_000, channel: 1)
            try expect(abs(Double(firstSystem) / Double(Int16.max) - 0.25) < 0.01)
            try expectEqual(firstMicrophone, 0)
            try expect(abs(Double(laterMicrophone) / Double(Int16.max) - 0.5) < 0.01)
        }
    }

    try runTest("a callback discontinuity remains silence in the final timeline") {
        try withTemporaryDirectory(prefix: "CallRecorderFinalizerTests") { root in
            let systemDirectory = root.appendingPathComponent("system", isDirectory: true)
            let microphoneDirectory = root.appendingPathComponent("microphone", isDirectory: true)
            try FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: microphoneDirectory, withIntermediateDirectories: true)
            let origin = AudioGetCurrentHostTime()
            try writeChunk(
                directory: systemDirectory,
                filename: "000000.caf",
                sample: 0.25,
                frames: 480,
                firstHostTime: origin
            )
            try writeChunk(
                directory: systemDirectory,
                filename: "000001.caf",
                sample: 0.25,
                frames: 480,
                firstHostTime: origin + AudioConvertNanosToHostTime(20_000_000)
            )
            try writeChunk(
                directory: microphoneDirectory,
                filename: "000000.caf",
                sample: 0,
                frames: 1_440,
                firstHostTime: origin
            )
            let output = root.appendingPathComponent("audio.wav")
            _ = try RecordingFinalizer().finalize(
                recordingDirectory: root,
                systemCaptureDirectory: systemDirectory,
                microphoneCaptureDirectory: microphoneDirectory,
                outputURL: output
            )
            let wav = try Data(contentsOf: output)
            try expect(sample(in: wav, frame: 700, channel: 0) == 0)
            try expect(sample(in: wav, frame: 1_100, channel: 0) != 0)
        }
    }

    try await runAsyncTest("post-processing recovers closed chunks into the planned destination") {
        try await withTemporaryDirectory(prefix: "CallRecorderFinalizerTests") { root in
            let store = RecordingStore(rootDirectory: root.appendingPathComponent("history"))
            var recording = try store.createRecording(
                language: .english,
                microphoneUID: "mic",
                microphoneName: "Mic"
            )
            let systemDirectory = try store.url(
                for: recording.files.systemCaptureDirectory,
                in: recording
            )
            let microphoneDirectory = try store.url(
                for: recording.files.microphoneCaptureDirectory,
                in: recording
            )
            let origin = AudioGetCurrentHostTime()
            try writeChunk(
                directory: systemDirectory,
                filename: "000000.caf",
                sample: 0.25,
                frames: 4_800,
                firstHostTime: origin
            )
            try writeChunk(
                directory: microphoneDirectory,
                filename: "000000.caf",
                sample: 0.5,
                frames: 4_800,
                firstHostTime: origin
            )
            let exportRoot = root.appendingPathComponent("exports", isDirectory: true)
            let destination = exportRoot.appendingPathComponent("Recovered Call", isDirectory: true)
            recording.captureStatus = .processing
            recording.files.exportDirectory = destination.path
            try store.save(recording)

            let result = try await RecordingPostProcessor().process(
                recording: recording,
                store: store
            )

            try expectEqual(result.publication.directoryURL, destination)
            try expect(FileManager.default.fileExists(atPath: result.publication.audioURL.path))
            let audio = try AVAudioFile(forReading: result.publication.audioURL)
            try expectEqual(audio.processingFormat.channelCount, 2)
            try expect(abs(result.publication.durationSeconds - 0.1) < 0.01)
        }
    }
}

private func writeChunk(
    directory: URL,
    filename: String,
    sample: Float,
    frames: AVAudioFrameCount,
    firstHostTime: UInt64,
    tailSample: Float? = nil,
    tailFrames: AVAudioFrameCount = 0
) throws {
    let url = directory.appendingPathComponent(filename)
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    do {
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let tailStart = Int(frames - min(frames, tailFrames))
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = if let tailSample, index >= tailStart {
                tailSample
            } else {
                sample
            }
        }
        try file.write(from: buffer)
    }
    let metadata =
        "{\"file\":\"\(filename)\",\"firstHostTime\":\(firstHostTime)," +
        "\"lastHostTime\":\(firstHostTime),\"lastFrames\":\(frames)," +
        "\"frames\":\(frames),\"sampleRate\":48000.0}\n"
    let metadataURL = directory.appendingPathComponent("chunks.jsonl")
    if FileManager.default.fileExists(atPath: metadataURL.path) {
        let handle = try FileHandle(forWritingTo: metadataURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(metadata.utf8))
    } else {
        try Data(metadata.utf8).write(to: metadataURL)
    }
}

private func sample(in wav: Data, frame: Int, channel: Int) -> Int16 {
    let offset = 44 + frame * 4 + channel * 2
    let value = wav.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
    }
    return Int16(bitPattern: UInt16(littleEndian: value))
}
