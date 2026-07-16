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

public struct RecordingStorageUsage: Equatable, Sendable {
    public var privateHistoryBytes: Int64
    public var recoveryBytes: Int64
    public var recoveryBytesByRecordingID: [UUID: Int64]

    public init(
        privateHistoryBytes: Int64 = 0,
        recoveryBytes: Int64 = 0,
        recoveryBytesByRecordingID: [UUID: Int64] = [:]
    ) {
        self.privateHistoryBytes = privateHistoryBytes
        self.recoveryBytes = recoveryBytes
        self.recoveryBytesByRecordingID = recoveryBytesByRecordingID
    }

    public static let zero = RecordingStorageUsage()
}

private enum ExternalFileResolution {
    case available(URL)
    case missing
    case unavailable

    var availableURL: URL? {
        if case .available(let url) = self { return url }
        return nil
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

public struct RecordingStore: Sendable {
    private static let discardMarkerName = ".discard-requested"
    private static let privateScratchNames: Set<String> = [
        ".audio.wav.partial",
        ".microphone-aligned.raw",
        ".system-aligned.raw",
    ]

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
            guard !fileManager.fileExists(
                atPath: directory.appendingPathComponent(Self.discardMarkerName).path
            ) else { continue }
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
            let hasPublishedFileEvidence = original.effectiveOrigin == .importedAudio ||
                original.files.audio != nil ||
                original.files.audioBookmark != nil ||
                (original.captureStatus == .complete &&
                    (original.files.transcriptMarkdown != nil ||
                        original.files.transcriptBookmark != nil))
            guard hasPublishedFileEvidence,
                  original.captureStatus != .recording,
                  original.captureStatus != .processing,
                  original.transcriptionStatus != .transcribing
            else { continue }

            var recording = original
            let audioResolution = try resolveExternalFile(
                path: recording.files.audio,
                bookmark: recording.files.audioBookmark,
                in: recording
            )
            var transcriptResolution = try resolveExternalFile(
                path: recording.files.transcriptMarkdown,
                bookmark: recording.files.transcriptBookmark,
                in: recording
            )
            if let transcriptURL = transcriptResolution.availableURL,
               recording.files.transcriptBookmark == nil,
               !transcriptMatchesRetainedResponse(transcriptURL, recording: recording) {
                transcriptResolution = .missing
            }
            let resolvedAudio = audioResolution.availableURL
            let resolvedTranscript = transcriptResolution.availableURL

            // Once a recording has been published, Finder is the source of truth.
            // Removing every public artifact also removes its private history entry.
            guard resolvedAudio != nil || resolvedTranscript != nil ||
                    audioResolution.isUnavailable || transcriptResolution.isUnavailable
            else {
                if recording.effectiveOrigin == .nativeRecording,
                   let exportDirectory = recording.files.exportDirectory {
                    try? AudioExportService.removePublicationMarker(
                        in: URL(fileURLWithPath: exportDirectory),
                        recordingID: recording.id
                    )
                }
                try delete(recording)
                continue
            }

            if let resolvedAudio {
                recording.files.audio = resolvedAudio.path
                recording.files.audioBookmark = try? bookmark(for: resolvedAudio)
                recording.files.exportDirectory = resolvedAudio.deletingLastPathComponent().path
                // An external audio path is persisted only after M4A validation (or
                // after validating an imported source), so private capture material
                // is no longer needed even if the app exited before normal cleanup.
                try? removeCaptureArtifacts(for: recording)
            } else if !audioResolution.isUnavailable {
                recording.files.audio = nil
                recording.files.audioBookmark = nil
            }

            if let resolvedTranscript {
                recording.files.transcriptMarkdown = resolvedTranscript.path
                recording.files.transcriptBookmark = try? bookmark(for: resolvedTranscript)
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
            } else if !transcriptResolution.isUnavailable {
                recording.files.transcriptBookmark = nil
                if let resolvedAudio {
                    if recording.files.transcriptMarkdown == nil {
                        recording.files.transcriptMarkdown = transcriptURL(
                            beside: resolvedAudio,
                            origin: recording.effectiveOrigin
                        ).path
                    }
                    if recording.transcriptionStatus == .complete {
                        recording.transcriptionStatus = .failed
                        let retryDescription = hasValidRetainedTranscriptResponse(for: recording)
                            ? "It can be recreated locally without another upload."
                            : "Creating it again requires a new paid Deepgram upload."
                        recording.lastFailure = RecordingFailure(
                            stage: .transcription,
                            message: "Transcript.md is missing in Finder. \(retryDescription)"
                        )
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
        try purgeDiscardRequestedRecordings()
        var recordings = try loadAll()
        var ghostRecordingIDs: Set<UUID> = []
        for index in recordings.indices {
            var recording = recordings[index]
            if recording.captureStatus == .recording {
                guard hasClosedCaptureMetadata(for: recording) else {
                    if recording.captureStartedAt == nil,
                       !hasAnyCaptureMaterial(for: recording) {
                        try markDiscardRequested(for: recording)
                        try? delete(recording)
                        ghostRecordingIDs.insert(recording.id)
                    } else {
                        recording.captureStatus = .failed
                        recording.transcriptionStatus = .failed
                        recording.lastFailure = RecordingFailure(
                            stage: .capture,
                            message: "The app exited while recording. Incomplete recovery audio was retained, but it cannot be finalized automatically.",
                            occurredAt: now
                        )
                        try save(recording)
                        recordings[index] = recording
                    }
                    continue
                }
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
                if hasValidRetainedTranscriptResponse(for: recording) {
                    recording.files.transcriptJSON = "transcript.json"
                    recording.transcriptionStatus = .notStarted
                    recording.lastFailure = nil
                    recording.warnings.append(
                        "Transcription was interrupted after Deepgram responded. The transcript will be recreated locally without another upload."
                    )
                } else {
                    recording.transcriptionStatus = .failed
                    recording.lastFailure = RecordingFailure(
                        stage: .transcription,
                        message: "Transcription was interrupted. Deepgram may already have processed the audio; retry manually if needed.",
                        occurredAt: now
                    )
                }
                try save(recording)
                recordings[index] = recording
            }
        }
        return recordings
            .filter { !ghostRecordingIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ manifest: RecordingManifest) throws {
        guard let directory = try findRecordingDirectory(id: manifest.id) else { return }
        try fileManager.removeItem(at: directory)
    }

    public func markDiscardRequested(for manifest: RecordingManifest) throws {
        let marker = try directory(for: manifest)
            .appendingPathComponent(Self.discardMarkerName)
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        do {
            try AtomicFilePublisher.publishNewFile(Data(), to: marker)
        } catch AtomicFilePublisherError.destinationExists {
            return
        }
    }

    public func purgeDiscardRequestedRecordings() throws {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  fileManager.fileExists(
                    atPath: directory.appendingPathComponent(Self.discardMarkerName).path
                  )
            else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }

    public func retainedTranscriptData(for manifest: RecordingManifest) throws -> Data? {
        let url = try directory(for: manifest).appendingPathComponent("transcript.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func expectsRetainedTranscriptResponse(for manifest: RecordingManifest) -> Bool {
        if manifest.files.transcriptJSON != nil { return true }
        guard let directory = try? directory(for: manifest) else { return false }
        return fileManager.fileExists(
            atPath: directory.appendingPathComponent("transcript.json").path
        )
    }

    public func hasValidRetainedTranscriptResponse(for manifest: RecordingManifest) -> Bool {
        guard let data = try? retainedTranscriptData(for: manifest) else { return false }
        return (try? TranscriptDocument(deepgramResponse: data)) != nil
    }

    public func removeRetainedTranscriptResponse(for manifest: RecordingManifest) throws {
        let url = try directory(for: manifest).appendingPathComponent("transcript.json")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
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
        try existingExternalURL(
            path: manifest.files.audio,
            bookmark: manifest.files.audioBookmark,
            in: manifest
        )
    }

    public func transcriptURL(for manifest: RecordingManifest) throws -> URL? {
        try existingExternalURL(
            path: manifest.files.transcriptMarkdown,
            bookmark: manifest.files.transcriptBookmark,
            in: manifest
        )
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
        availableURL(for: transcriptURL(beside: audioURL, origin: origin))
    }

    public func availableURL(for preferred: URL) -> URL {
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

    public func hasClosedCaptureMetadata(for manifest: RecordingManifest) -> Bool {
        guard let directory = try? directory(for: manifest) else { return false }
        return ["capture/system", "capture/microphone"].allSatisfy { relativePath in
            hasRecoverableCapture(in: directory.appendingPathComponent(relativePath))
        }
    }

    private func hasAnyCaptureMaterial(for manifest: RecordingManifest) -> Bool {
        guard let directory = try? directory(for: manifest) else { return false }
        for relativePath in ["capture/system", "capture/microphone"] {
            let captureDirectory = directory.appendingPathComponent(relativePath)
            guard let enumerator = fileManager.enumerator(
                at: captureDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                ) else { continue }
                if values.isRegularFile == true, values.isSymbolicLink != true {
                    return true
                }
            }
        }
        return false
    }

    public func storageUsage() throws -> RecordingStorageUsage {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return .zero }
        var usage = RecordingStorageUsage.zero
        let knownRecordingIDs = try loadAll().map(\.id)
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return usage }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            usage.privateHistoryBytes += bytes
            let components = url.pathComponents
            if components.contains("capture") ||
                url.lastPathComponent == "audio.wav" ||
                Self.privateScratchNames.contains(url.lastPathComponent) {
                usage.recoveryBytes += bytes
                if let id = knownRecordingIDs.first(where: { id in
                    components.contains(where: { $0.hasSuffix(id.uuidString) })
                }) {
                    usage.recoveryBytesByRecordingID[id, default: 0] += bytes
                }
            }
        }
        return usage
    }

    public func cleanupStalePrivateArtifacts(
        olderThan cutoff: Date
    ) throws {
        guard fileManager.fileExists(atPath: rootDirectory.path),
              let enumerator = fileManager.enumerator(
                at: rootDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ],
                options: [],
                errorHandler: { _, _ in true }
              )
        else { return }
        for case let url as URL in enumerator {
            guard Self.privateScratchNames.contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff
            else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    public func forgetAllHistory() throws {
        if fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.removeItem(at: rootDirectory)
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

    private func existingExternalURL(
        path: String?,
        bookmark: Data?,
        in manifest: RecordingManifest
    ) throws -> URL? {
        try resolveExternalFile(
            path: path,
            bookmark: bookmark,
            in: manifest
        ).availableURL
    }

    private func resolveExternalFile(
        path: String?,
        bookmark: Data?,
        in manifest: RecordingManifest
    ) throws -> ExternalFileResolution {
        if let bookmark {
            guard let resolved = resolveBookmark(bookmark) else {
                guard let path else { return .unavailable }
                let storedURL = try fileURL(for: path, in: manifest)
                return isOnUnavailableExternalVolume(storedURL) ? .unavailable : .missing
            }
            if isInTrash(resolved) { return .missing }
            if fileManager.fileExists(atPath: resolved.path) { return .available(resolved) }
            return isOnUnavailableExternalVolume(resolved) ? .unavailable : .missing
        }
        if let path {
            let url = try fileURL(for: path, in: manifest)
            if isInTrash(url) { return .missing }
            if fileManager.fileExists(atPath: url.path) { return .available(url) }
            return isOnUnavailableExternalVolume(url) ? .unavailable : .missing
        }
        return .missing
    }

    private func isInTrash(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.contains { component in
            component == ".Trash" || component == ".Trashes"
        }
    }

    private func isOnUnavailableExternalVolume(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return false }
        let volumeRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
        return !fileManager.fileExists(atPath: volumeRoot.path)
    }

    private func transcriptMatchesRetainedResponse(
        _ transcriptURL: URL,
        recording: RecordingManifest
    ) -> Bool {
        guard let response = try? retainedTranscriptData(for: recording),
              let document = try? TranscriptDocument(deepgramResponse: response),
              let existing = try? Data(contentsOf: transcriptURL)
        else { return false }
        let expected = Data(
            TranscriptMarkdownFormatter.format(document: document, recording: recording).utf8
        )
        return existing == expected
    }

    private func hasRecoverableCapture(in directory: URL) -> Bool {
        let metadataURL = directory.appendingPathComponent("chunks.jsonl")
        guard let data = try? Data(contentsOf: metadataURL) else { return false }
        let completeData: Data
        if data.last == 0x0a {
            completeData = data
        } else if let lastNewline = data.lastIndex(of: 0x0a) {
            completeData = Data(data.prefix(through: lastNewline))
        } else {
            return false
        }
        let decoder = JSONDecoder()
        guard let chunks = try? completeData
            .split(separator: 0x0a, omittingEmptySubsequences: true)
            .map({ try decoder.decode(CaptureChunk.self, from: Data($0)) }),
              !chunks.isEmpty,
              chunks.allSatisfy(\.isValid)
        else { return false }
        return chunks.allSatisfy { chunk in
            let url = directory.appendingPathComponent(chunk.file)
            guard fileManager.isReadableFile(atPath: url.path),
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                  )
            else { return false }
            return values.isRegularFile == true &&
                values.isSymbolicLink != true &&
                (values.fileSize ?? 0) > 0
        }
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
