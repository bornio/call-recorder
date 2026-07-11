@preconcurrency import AVFoundation
import CoreAudio
import Foundation

public struct FinalizationResult: Equatable, Sendable {
    public var audioURL: URL
    public var durationSeconds: Double
    public var warnings: [String]

    public init(audioURL: URL, durationSeconds: Double, warnings: [String]) {
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
        self.warnings = warnings
    }
}

public enum RecordingFinalizerError: LocalizedError, Sendable {
    case missingCaptureMetadata(source: String)
    case invalidCaptureMetadata(source: String)
    case missingCaptureChunk(String)
    case unsupportedCaptureChunk(String)
    case emptyCaptureChunk(String)
    case recordingTooLong
    case fileCreation(URL)

    public var errorDescription: String? {
        switch self {
        case .missingCaptureMetadata(let source):
            "No closed \(source) capture chunks were available to finalize."
        case .invalidCaptureMetadata(let source):
            "The \(source) capture metadata is incomplete or damaged."
        case .missingCaptureChunk(let filename):
            "Capture chunk \(filename) is missing."
        case .unsupportedCaptureChunk(let filename):
            "Capture chunk \(filename) does not contain readable mono PCM audio."
        case .emptyCaptureChunk(let filename):
            "Capture chunk \(filename) is empty."
        case .recordingTooLong:
            "The finalized WAV would exceed the 4 GB WAV size limit."
        case .fileCreation(let url):
            "Unable to create \(url.lastPathComponent)."
        }
    }
}

public struct RecordingFinalizer: Sendable {
    public static let outputSampleRate = 48_000

    public init() {}

    public func finalize(
        recordingDirectory: URL,
        systemCaptureDirectory: URL,
        microphoneCaptureDirectory: URL,
        outputURL: URL
    ) throws -> FinalizationResult {
        let systemChunks = try loadMetadata(
            from: systemCaptureDirectory,
            source: "system-audio"
        )
        let microphoneChunks = try loadMetadata(
            from: microphoneCaptureDirectory,
            source: "microphone"
        )
        guard let origin = (systemChunks + microphoneChunks)
            .map(\.firstHostTime)
            .min()
        else {
            throw RecordingFinalizerError.invalidCaptureMetadata(source: "audio")
        }

        let systemRawURL = recordingDirectory.appendingPathComponent(".system-aligned.raw")
        let microphoneRawURL = recordingDirectory.appendingPathComponent(".microphone-aligned.raw")
        let partialOutputURL = recordingDirectory.appendingPathComponent(".audio.wav.partial")
        let temporaryURLs = [systemRawURL, microphoneRawURL, partialOutputURL]
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        defer {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var warnings: [String] = []
        let systemFrames = try align(
            chunks: systemChunks,
            captureDirectory: systemCaptureDirectory,
            originHostTime: origin,
            rawURL: systemRawURL,
            sourceName: "system audio",
            warnings: &warnings
        )
        let microphoneFrames = try align(
            chunks: microphoneChunks,
            captureDirectory: microphoneCaptureDirectory,
            originHostTime: origin,
            rawURL: microphoneRawURL,
            sourceName: "microphone",
            warnings: &warnings
        )
        let totalFrames = max(systemFrames, microphoneFrames)
        guard totalFrames > 0 else {
            throw RecordingFinalizerError.invalidCaptureMetadata(source: "audio")
        }

        try writeStereoWAV(
            systemRawURL: systemRawURL,
            microphoneRawURL: microphoneRawURL,
            frameCount: totalFrames,
            outputURL: partialOutputURL
        )
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: partialOutputURL, to: outputURL)

        return FinalizationResult(
            audioURL: outputURL,
            durationSeconds: Double(totalFrames) / Double(Self.outputSampleRate),
            warnings: warnings
        )
    }

    private func loadMetadata(from directory: URL, source: String) throws -> [CaptureChunk] {
        let metadataURL = directory.appendingPathComponent("chunks.jsonl")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw RecordingFinalizerError.missingCaptureMetadata(source: source)
        }
        let data = try Data(contentsOf: metadataURL)
        let completeData: Data
        if data.last == 0x0a {
            completeData = data
        } else if let lastNewline = data.lastIndex(of: 0x0a) {
            completeData = data.prefix(through: lastNewline)
        } else {
            completeData = Data()
        }
        let lines = completeData.split(separator: 0x0a, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        let chunks: [CaptureChunk]
        do {
            chunks = try lines.map { line in
                try decoder.decode(CaptureChunk.self, from: Data(line))
            }
        } catch {
            throw RecordingFinalizerError.invalidCaptureMetadata(source: source)
        }
        guard !chunks.isEmpty else {
            throw RecordingFinalizerError.missingCaptureMetadata(source: source)
        }
        guard chunks.allSatisfy({ $0.isValid }) else {
            throw RecordingFinalizerError.invalidCaptureMetadata(source: source)
        }
        return chunks.sorted { $0.firstHostTime < $1.firstHostTime }
    }

    private func align(
        chunks: [CaptureChunk],
        captureDirectory: URL,
        originHostTime: UInt64,
        rawURL: URL,
        sourceName: String,
        warnings: inout [String]
    ) throws -> UInt64 {
        guard FileManager.default.createFile(atPath: rawURL.path, contents: nil) else {
            throw RecordingFinalizerError.fileCreation(rawURL)
        }
        let output = try FileHandle(forWritingTo: rawURL)
        defer { try? output.close() }

        var priorEnd: UInt64 = 0
        for chunk in chunks {
            let chunkURL = captureDirectory
                .appendingPathComponent(chunk.file)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let captureRoot = captureDirectory
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path + "/"
            guard chunkURL.path.hasPrefix(captureRoot),
                  FileManager.default.fileExists(atPath: chunkURL.path)
            else {
                throw RecordingFinalizerError.missingCaptureChunk(chunk.file)
            }

            let samples = try readMonoSamples(from: chunkURL)
            guard !samples.isEmpty else {
                throw RecordingFinalizerError.emptyCaptureChunk(chunk.file)
            }
            if UInt64(samples.count) != chunk.frames {
                warnings.append(
                    "\(sourceName.capitalized) chunk \(chunk.file) contained \(samples.count) frames; metadata reported \(chunk.frames)."
                )
            }

            let nominalDuration = Double(samples.count) / chunk.sampleRate
            let hostDelta = chunk.lastHostTime >= chunk.firstHostTime
                ? chunk.lastHostTime - chunk.firstHostTime
                : 0
            let hostDuration = Double(AudioConvertHostTimeToNanos(hostDelta)) / 1_000_000_000
                + Double(chunk.lastFrames) / chunk.sampleRate
            let duration: Double
            if hostDuration >= nominalDuration * 0.8 && hostDuration <= nominalDuration * 1.2 {
                duration = hostDuration
            } else {
                duration = nominalDuration
                warnings.append(
                    "\(sourceName.capitalized) timing was inconsistent in \(chunk.file); nominal timing was used."
                )
            }
            let targetCount = max(1, Int((duration * Double(Self.outputSampleRate)).rounded()))
            let resampled = linearResample(samples, outputCount: targetCount)

            let originDelta = chunk.firstHostTime >= originHostTime
                ? chunk.firstHostTime - originHostTime
                : 0
            var start = UInt64(
                (Double(AudioConvertHostTimeToNanos(originDelta)) / 1_000_000_000
                    * Double(Self.outputSampleRate)).rounded()
            )
            // Snap only sub-frame rounding noise. A real callback gap must remain silence.
            let snapTolerance: UInt64 = 2
            if priorEnd > 0 {
                let distance = start > priorEnd ? start - priorEnd : priorEnd - start
                if distance <= snapTolerance {
                    start = priorEnd
                } else if start < priorEnd {
                    warnings.append(
                        "Overlapping \(sourceName) chunks were kept sequential to avoid duplicated audio."
                    )
                    start = priorEnd
                }
            }

            try output.seek(toOffset: start * UInt64(MemoryLayout<Float>.stride))
            try resampled.withUnsafeBytes { bytes in
                try output.write(contentsOf: Data(bytes))
            }
            priorEnd = start + UInt64(resampled.count)
        }
        try output.synchronize()
        return priorEnd
    }

    private func readMonoSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount == 1,
              format.commonFormat == .pcmFormatFloat32,
              file.length > 0,
              file.length <= AVAudioFramePosition(UInt32.max)
        else {
            throw RecordingFinalizerError.unsupportedCaptureChunk(url.lastPathComponent)
        }
        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RecordingFinalizerError.unsupportedCaptureChunk(url.lastPathComponent)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw RecordingFinalizerError.unsupportedCaptureChunk(url.lastPathComponent)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func linearResample(_ input: [Float], outputCount: Int) -> [Float] {
        guard outputCount > 0 else { return [] }
        guard input.count > 1, outputCount > 1 else {
            return [Float](repeating: input.first ?? 0, count: outputCount)
        }
        if input.count == outputCount { return input }
        let scale = Double(input.count - 1) / Double(outputCount - 1)
        return (0..<outputCount).map { outputIndex in
            let position = Double(outputIndex) * scale
            let lower = Int(position)
            let upper = min(lower + 1, input.count - 1)
            let fraction = Float(position - Double(lower))
            return input[lower] + (input[upper] - input[lower]) * fraction
        }
    }

    private func writeStereoWAV(
        systemRawURL: URL,
        microphoneRawURL: URL,
        frameCount: UInt64,
        outputURL: URL
    ) throws {
        let bytesPerFrame: UInt64 = 4
        let dataByteCount = frameCount * bytesPerFrame
        guard dataByteCount <= UInt64(UInt32.max) - 36 else {
            throw RecordingFinalizerError.recordingTooLong
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw RecordingFinalizerError.fileCreation(outputURL)
        }

        let system = try FileHandle(forReadingFrom: systemRawURL)
        let microphone = try FileHandle(forReadingFrom: microphoneRawURL)
        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? system.close()
            try? microphone.close()
            try? output.close()
        }

        try output.write(contentsOf: wavHeader(dataByteCount: UInt32(dataByteCount)))
        let blockFrames = 8_192
        var written: UInt64 = 0
        while written < frameCount {
            let count = min(blockFrames, Int(frameCount - written))
            let systemSamples = try readFloatBlock(from: system, count: count)
            let microphoneSamples = try readFloatBlock(from: microphone, count: count)
            var interleaved = [Int16](repeating: 0, count: count * 2)
            for index in 0..<count {
                interleaved[index * 2] = pcm16(systemSamples[index])
                interleaved[index * 2 + 1] = pcm16(microphoneSamples[index])
            }
            try interleaved.withUnsafeBytes { bytes in
                try output.write(contentsOf: Data(bytes))
            }
            written += UInt64(count)
        }
        try output.synchronize()
    }

    private func readFloatBlock(from handle: FileHandle, count: Int) throws -> [Float] {
        let byteCount = count * MemoryLayout<Float>.stride
        var data = Data()
        data.reserveCapacity(byteCount)
        while data.count < byteCount {
            guard let chunk = try handle.read(upToCount: byteCount - data.count),
                  !chunk.isEmpty
            else { break }
            data.append(chunk)
        }
        var samples = [Float](repeating: 0, count: count)
        let copyCount = min(data.count, byteCount)
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination, count: copyCount)
        }
        return samples
    }

    private func pcm16(_ sample: Float) -> Int16 {
        let clamped = max(-1, min(sample, 1))
        if clamped <= -1 { return Int16.min }
        return Int16((clamped * Float(Int16.max)).rounded())
    }

    private func wavHeader(dataByteCount: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20]) // fmt
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt32(Self.outputSampleRate))
        data.appendLittleEndian(UInt32(Self.outputSampleRate * 4))
        data.appendLittleEndian(UInt16(4))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        data.appendLittleEndian(dataByteCount)
        return data
    }
}

private struct CaptureChunk: Decodable, Sendable {
    var file: String
    var firstHostTime: UInt64
    var lastHostTime: UInt64
    var lastFrames: UInt32
    var frames: UInt64
    var sampleRate: Double

    var isValid: Bool {
        !file.isEmpty &&
            !file.contains("/") &&
            firstHostTime > 0 &&
            lastHostTime >= firstHostTime &&
            lastFrames > 0 &&
            frames > 0 &&
            sampleRate.isFinite &&
            sampleRate > 0
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
