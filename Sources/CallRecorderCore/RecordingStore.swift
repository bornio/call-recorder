import Foundation

public enum RecordingStoreError: LocalizedError, Sendable {
    case invalidRelativePath(String)
    case missingManifest(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path): "Invalid recording path: \(path)"
        case .missingManifest(let id): "Recording \(id.uuidString) no longer exists."
        }
    }
}

public struct RecordingStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    private var fileManager: FileManager { .default }

    public static var defaultRootDirectory: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Call Recorder", isDirectory: true)
    }

    public static var defaultHistoryDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Call Recorder", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    @discardableResult
    public func createRecording(
        language: RecordingLanguage,
        microphoneUID: String,
        microphoneName: String,
        localSpeakerName: String? = nil,
        keyterms: [String]? = nil,
        now: Date = Date(),
        id: UUID = UUID()
    ) throws -> RecordingManifest {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let directory = recordingDirectory(id: id, createdAt: now)
        try fileManager.createDirectory(
            at: directory.appendingPathComponent("capture/system", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: directory.appendingPathComponent("capture/microphone", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest = RecordingManifest(
            id: id,
            createdAt: now,
            language: language,
            microphoneUID: microphoneUID,
            microphoneName: microphoneName,
            localSpeakerName: localSpeakerName,
            keyterms: keyterms
        )
        try save(manifest, in: directory)
        return manifest
    }

    public func save(_ manifest: RecordingManifest) throws {
        guard let directory = try findRecordingDirectory(id: manifest.id) else {
            throw RecordingStoreError.missingManifest(manifest.id)
        }
        try save(manifest, in: directory)
    }

    public func loadAll() throws -> [RecordingManifest] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .creationDateKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )
        var recordings: [RecordingManifest] = []
        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? Self.decoder.decode(RecordingManifest.self, from: data),
               manifest.version == RecordingManifest.currentVersion {
                recordings.append(manifest)
            } else if let recoveryManifest = recoveryManifest(for: directory) {
                recordings.append(recoveryManifest)
            }
        }
        return recordings.sorted { $0.createdAt > $1.createdAt }
    }

    public func load(id: UUID) throws -> RecordingManifest {
        guard let directory = try findRecordingDirectory(id: id) else {
            throw RecordingStoreError.missingManifest(id)
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? Self.decoder.decode(RecordingManifest.self, from: data),
           manifest.version == RecordingManifest.currentVersion {
            return manifest
        }
        if let recovery = recoveryManifest(for: directory) {
            return recovery
        }
        throw RecordingStoreError.missingManifest(id)
    }

    @discardableResult
    public func reconcileExternalFiles() throws -> [RecordingManifest] {
        for original in try loadAll() {
            guard original.effectiveOrigin == .importedAudio ||
                    original.files.audio != nil ||
                    original.files.audioBookmark != nil,
                  original.captureStatus != .recording,
                  original.captureStatus != .processing
            else { continue }

            var recording = original
            let resolvedAudio = try audioURL(for: recording)
            let resolvedTranscript = try transcriptURL(for: recording)

            // Once a recording has been published, Finder is the source of truth.
            // Removing every public artifact also removes its private history entry.
            guard resolvedAudio != nil || resolvedTranscript != nil else {
                try delete(recording)
                continue
            }

            if let resolvedAudio {
                recording.files.audio = resolvedAudio.path
                if recording.files.audioBookmark == nil {
                    recording.files.audioBookmark = try? bookmark(for: resolvedAudio)
                }
                recording.files.exportDirectory = resolvedAudio.deletingLastPathComponent().path
                // An external audio path is persisted only after M4A validation (or
                // after validating an imported source), so private capture material
                // is no longer needed even if the app exited before normal cleanup.
                try? removeCaptureArtifacts(for: recording)
            } else {
                recording.files.audio = nil
                recording.files.audioBookmark = nil
            }

            if let resolvedTranscript {
                recording.files.transcriptMarkdown = resolvedTranscript.path
                if recording.files.transcriptBookmark == nil {
                    recording.files.transcriptBookmark = try? bookmark(for: resolvedTranscript)
                }
                if recording.files.exportDirectory == nil {
                    recording.files.exportDirectory = resolvedTranscript.deletingLastPathComponent().path
                }
                let privateJSON = try directory(for: recording)
                    .appendingPathComponent("transcript.json")
                if recording.transcriptionStatus != .complete,
                   fileManager.fileExists(atPath: privateJSON.path) {
                    recording.files.transcriptJSON = "transcript.json"
                    recording.transcriptionStatus = .complete
                    if recording.lastFailure?.stage == .transcription {
                        recording.lastFailure = nil
                    }
                }
            } else {
                recording.files.transcriptBookmark = nil
                if let resolvedAudio {
                    if recording.files.transcriptMarkdown == nil {
                        recording.files.transcriptMarkdown = transcriptURL(
                            beside: resolvedAudio,
                            origin: recording.effectiveOrigin
                        ).path
                    }
                    if recording.transcriptionStatus == .complete {
                        recording.transcriptionStatus = .notStarted
                        if recording.lastFailure?.stage == .transcription {
                            recording.lastFailure = nil
                        }
                    }
                } else {
                    recording.files.transcriptMarkdown = nil
                }
            }

            if recording != original {
                try save(recording)
            }
        }
        return try loadAll()
    }

    @discardableResult
    public func recoverInterruptedRecordings(now: Date = Date()) throws -> [RecordingManifest] {
        var recordings = try loadAll()
        for index in recordings.indices {
            var recording = recordings[index]
            if recording.captureStatus == .recording {
                recording.captureStatus = .processing
                recording.transcriptionStatus = .notStarted
                recording.lastFailure = RecordingFailure(
                    stage: .finalization,
                    message: "The app exited while recording. Closed capture chunks will be recovered.",
                    occurredAt: now
                )
                try save(recording)
                recordings[index] = recording
            } else if recording.captureStatus == .processing {
                if recording.lastFailure?.stage == .capture {
                    let warning = "Finalization was interrupted and will resume."
                    if !recording.warnings.contains(warning) {
                        recording.warnings.append(warning)
                    }
                } else {
                    recording.lastFailure = RecordingFailure(
                        stage: .finalization,
                        message: "The app exited before recording finalization completed. Recovery will resume.",
                        occurredAt: now
                    )
                }
                try save(recording)
                recordings[index] = recording
            } else if recording.transcriptionStatus == .transcribing {
                recording.transcriptionStatus = .notStarted
                recording.lastFailure = nil
                recording.warnings.append(
                    "Transcription was interrupted and queued to resume."
                )
                try save(recording)
                recordings[index] = recording
            }
        }
        return recordings.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ manifest: RecordingManifest) throws {
        guard let directory = try findRecordingDirectory(id: manifest.id) else { return }
        try fileManager.removeItem(at: directory)
    }

    public func removeCaptureArtifacts(for manifest: RecordingManifest) throws {
        let directory = try directory(for: manifest)
        let captureDirectory = directory.appendingPathComponent("capture", isDirectory: true)
        if fileManager.fileExists(atPath: captureDirectory.path) {
            try fileManager.removeItem(at: captureDirectory)
        }
        let waveURL = directory.appendingPathComponent("audio.wav")
        if fileManager.fileExists(atPath: waveURL.path) {
            try fileManager.removeItem(at: waveURL)
        }
    }

    public func directory(for manifest: RecordingManifest) throws -> URL {
        guard let directory = try findRecordingDirectory(id: manifest.id) else {
            throw RecordingStoreError.missingManifest(manifest.id)
        }
        return directory
    }

    public func url(for relativePath: String, in manifest: RecordingManifest) throws -> URL {
        let directory = try directory(for: manifest).resolvingSymlinksInPath().standardizedFileURL
        let path = relativePath as NSString
        let components = path.pathComponents
        guard !path.isAbsolutePath,
              !components.contains("..")
        else {
            throw RecordingStoreError.invalidRelativePath(relativePath)
        }
        var candidate = directory
        for component in components where component != "." {
            candidate.appendPathComponent(component)
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw RecordingStoreError.invalidRelativePath(relativePath)
            }
        }
        candidate = candidate.standardizedFileURL
        let rootPath = directory.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw RecordingStoreError.invalidRelativePath(relativePath)
        }
        return candidate
    }

    public func fileURL(for path: String, in manifest: RecordingManifest) throws -> URL {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return try url(for: path, in: manifest)
    }

    public func audioURL(for manifest: RecordingManifest) throws -> URL? {
        if let bookmark = manifest.files.audioBookmark,
           let resolved = resolveBookmark(bookmark),
           fileManager.fileExists(atPath: resolved.path) {
            return resolved
        }
        guard let path = manifest.files.audio else { return nil }
        let url = try fileURL(for: path, in: manifest)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func transcriptURL(for manifest: RecordingManifest) throws -> URL? {
        if let bookmark = manifest.files.transcriptBookmark,
           let resolved = resolveBookmark(bookmark),
           fileManager.fileExists(atPath: resolved.path) {
            return resolved
        }
        guard let path = manifest.files.transcriptMarkdown else { return nil }
        let url = try fileURL(for: path, in: manifest)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    public func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func availableTranscriptURL(
        beside audioURL: URL,
        origin: RecordingOrigin
    ) -> URL {
        let preferred = transcriptURL(beside: audioURL, origin: origin)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }

        let directory = preferred.deletingLastPathComponent()
        let basename = preferred.deletingPathExtension().lastPathComponent
        let pathExtension = preferred.pathExtension
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent(
                "\(basename) (\(suffix))"
            ).appendingPathExtension(pathExtension)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ).standardizedFileURL
    }

    public func transcriptURL(beside audioURL: URL, origin: RecordingOrigin) -> URL {
        let filename: String
        if origin == .nativeRecording || audioURL.deletingPathExtension().lastPathComponent == "Audio" {
            filename = "Transcript.md"
        } else {
            filename = "\(audioURL.deletingPathExtension().lastPathComponent).md"
        }
        return audioURL.deletingLastPathComponent().appendingPathComponent(filename)
    }

    private func save(_ manifest: RecordingManifest, in directory: URL) throws {
        let data = try Self.encoder.encode(manifest)
        try data.write(
            to: directory.appendingPathComponent("manifest.json"),
            options: [.atomic]
        )
    }

    private func findRecordingDirectory(id: UUID) throws -> URL? {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return nil }
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.first { $0.lastPathComponent.hasSuffix("-\(id.uuidString)") }
    }

    private func recoveryManifest(for directory: URL) -> RecordingManifest? {
        let identifierText = String(directory.lastPathComponent.suffix(36))
        guard let identifier = UUID(uuidString: identifierText) else { return nil }
        let values = try? directory.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
        var manifest = RecordingManifest(
            id: identifier,
            createdAt: createdAt,
            language: .english,
            microphoneUID: "",
            microphoneName: "Unknown microphone"
        )
        manifest.captureStatus = .failed
        manifest.lastFailure = RecordingFailure(
            stage: .finalization,
            message: "The recording manifest is missing or damaged. Recovery files were retained."
        )
        return manifest
    }

    private func recordingDirectory(id: UUID, createdAt: Date) -> URL {
        let timestamp = Self.directoryDateFormatter.string(from: createdAt)
        return rootDirectory.appendingPathComponent(
            "Call-\(timestamp)-\(id.uuidString)",
            isDirectory: true
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            let wholeSeconds = ISO8601DateFormatter()
            guard let date = wholeSeconds.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }()

    private static let directoryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
