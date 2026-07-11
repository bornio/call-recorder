@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

public struct PublishedRecordingAudio: Equatable, Sendable {
    public var directoryURL: URL
    public var audioURL: URL
    public var durationSeconds: Double

    public init(directoryURL: URL, audioURL: URL, durationSeconds: Double) {
        self.directoryURL = directoryURL
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
    }
}

public enum AudioExportError: LocalizedError, Sendable {
    case invalidSource
    case invalidCompressedAudio
    case unableToCreateExportDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            "The finalized recording is not a readable two-channel audio file."
        case .invalidCompressedAudio:
            "The compressed audio could not be validated. Recovery files were preserved."
        case .unableToCreateExportDirectory:
            "The clean recording folder could not be created."
        }
    }
}

public struct AudioExportService: Sendable {
    public static let bitRate = 128_000

    public init() {}

    public func publish(
        waveURL: URL,
        recording: RecordingManifest,
        exportRoot: URL,
        destinationDirectory: URL? = nil
    ) throws -> PublishedRecordingAudio {
        let source = try AVAudioFile(forReading: waveURL)
        guard source.processingFormat.channelCount == 2,
              source.processingFormat.sampleRate > 0,
              source.length > 0
        else {
            throw AudioExportError.invalidSource
        }

        try FileManager.default.createDirectory(
            at: exportRoot,
            withIntermediateDirectories: true
        )
        let stagingDirectory = exportRoot.appendingPathComponent(
            ".call-recorder-\(recording.id.uuidString).partial",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: stagingDirectory)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false
        )
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        let stagedAudio = stagingDirectory.appendingPathComponent("Audio.m4a")
        try encodeM4A(source: source, destination: stagedAudio)
        let validatedDuration = try validate(
            audioURL: stagedAudio,
            expectedDuration: Double(source.length) / source.processingFormat.sampleRate
        )

        let destinationDirectory = destinationDirectory ?? publicationDirectory(
            for: recording,
            in: exportRoot
        )
        guard destinationDirectory.deletingLastPathComponent().standardizedFileURL ==
                exportRoot.standardizedFileURL
        else {
            throw AudioExportError.unableToCreateExportDirectory
        }
        do {
            try FileManager.default.moveItem(
                at: stagingDirectory,
                to: destinationDirectory
            )
        } catch {
            throw AudioExportError.unableToCreateExportDirectory
        }
        committed = true

        let audioURL = destinationDirectory.appendingPathComponent("Audio.m4a")
        let dates: [FileAttributeKey: Any] = [
            .creationDate: recording.effectiveStartedAt,
            .modificationDate: recording.effectiveEndedAt ?? recording.effectiveStartedAt,
        ]
        try? FileManager.default.setAttributes(dates, ofItemAtPath: audioURL.path)
        try? FileManager.default.setAttributes(dates, ofItemAtPath: destinationDirectory.path)

        return PublishedRecordingAudio(
            directoryURL: destinationDirectory,
            audioURL: audioURL,
            durationSeconds: validatedDuration
        )
    }

    public func recoverPublication(in directoryURL: URL) throws -> PublishedRecordingAudio {
        let audioURL = directoryURL.appendingPathComponent("Audio.m4a")
        let duration = try validate(audioURL: audioURL, expectedDuration: nil)
        return PublishedRecordingAudio(
            directoryURL: directoryURL,
            audioURL: audioURL,
            durationSeconds: duration
        )
    }

    public func publicationDirectory(
        for recording: RecordingManifest,
        in root: URL
    ) -> URL {
        availableDestination(
            in: root,
            startedAt: recording.effectiveStartedAt,
            timeZoneIdentifier: recording.timeZoneIdentifier
        )
    }

    private func encodeM4A(source: AVAudioFile, destination: URL) throws {
        let processingFormat = source.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: processingFormat.sampleRate,
            AVNumberOfChannelsKey: Int(processingFormat.channelCount),
            AVEncoderBitRateKey: Self.bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: processingFormat.commonFormat,
            interleaved: processingFormat.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: 8_192
        ) else {
            throw AudioExportError.invalidSource
        }
        while source.framePosition < source.length {
            buffer.frameLength = 0
            try source.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    private func validate(audioURL: URL, expectedDuration: Double?) throws -> Double {
        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: audioURL)
        } catch {
            throw AudioExportError.invalidCompressedAudio
        }
        guard audio.processingFormat.channelCount == 2,
              audio.processingFormat.sampleRate > 0,
              audio.length > 0
        else {
            throw AudioExportError.invalidCompressedAudio
        }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        if let expectedDuration {
            guard abs(duration - expectedDuration) < max(0.5, expectedDuration * 0.01) else {
                throw AudioExportError.invalidCompressedAudio
            }
        }
        return duration
    }

    private func availableDestination(
        in root: URL,
        startedAt: Date,
        timeZoneIdentifier: String?
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let baseName = "\(formatter.string(from: startedAt)) — Call"
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName) (\(suffix))"
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}
