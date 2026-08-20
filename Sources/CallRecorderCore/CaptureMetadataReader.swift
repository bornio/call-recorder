import Foundation

enum CaptureMetadataReaderError: Error {
    case missing
    case invalid
}

enum CaptureMetadataReader {
    static func read(from metadataURL: URL) throws -> [CaptureChunk] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw CaptureMetadataReaderError.missing
        }

        let data = try Data(contentsOf: metadataURL)
        let completeData: Data
        if data.last == 0x0a {
            completeData = data
        } else if let lastNewline = data.lastIndex(of: 0x0a) {
            completeData = Data(data.prefix(through: lastNewline))
        } else {
            completeData = Data()
        }

        let lines = completeData.split(separator: 0x0a, omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw CaptureMetadataReaderError.missing }

        let decoder = JSONDecoder()
        let chunks: [CaptureChunk]
        do {
            chunks = try lines.map { try decoder.decode(CaptureChunk.self, from: Data($0)) }
        } catch {
            throw CaptureMetadataReaderError.invalid
        }
        guard chunks.allSatisfy(\.isValid) else {
            throw CaptureMetadataReaderError.invalid
        }
        return chunks
    }
}
