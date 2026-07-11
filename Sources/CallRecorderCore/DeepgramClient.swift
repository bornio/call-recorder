import Foundation

public enum DeepgramError: LocalizedError, Sendable {
    case invalidEndpoint
    case unreadableAudio
    case transport(String)
    case rejected(statusCode: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Unable to build the Deepgram prerecorded endpoint."
        case .unreadableAudio: "The finalized audio file cannot be read."
        case .transport(let message): "Deepgram request failed: \(message)"
        case .rejected(let statusCode, let message):
            "Deepgram returned HTTP \(statusCode): \(message)"
        case .invalidResponse: "Deepgram returned an invalid transcription response."
        }
    }
}

public enum DeepgramKeyterms {
    public static let maximumCount = 100

    public static func parse(_ text: String) -> [String] {
        normalized(text.components(separatedBy: .newlines))
    }

    public static func normalized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { value in
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term).inserted else { return nil }
            return term
        }
    }

    public static func limited(_ terms: [String]) -> [String] {
        Array(normalized(terms).prefix(maximumCount))
    }
}

public enum DeepgramRequestFactory {
    public static func makeRequest(
        language: RecordingLanguage,
        apiKey: String,
        contentType: String = "audio/wav",
        keyterms: [String] = []
    ) throws -> URLRequest {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")
        var queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: language.rawValue),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "paragraphs", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "utt_split", value: "1.0"),
            URLQueryItem(name: "multichannel", value: "true"),
            URLQueryItem(name: "diarize_model", value: "latest"),
            URLQueryItem(name: "mip_opt_out", value: "true"),
            URLQueryItem(name: "tag", value: "call-recorder"),
        ]
        queryItems.append(contentsOf: DeepgramKeyterms.limited(keyterms).map {
            URLQueryItem(name: "keyterm", value: $0)
        })
        components?.queryItems = queryItems
        guard let url = components?.url else { throw DeepgramError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30 * 60
        return request
    }

    static func contentType(for audioURL: URL) -> String {
        switch audioURL.pathExtension.lowercased() {
        case "m4a", "mp4": "audio/mp4"
        case "aac": "audio/aac"
        case "mp3", "mp2": "audio/mpeg"
        case "flac": "audio/flac"
        case "ogg", "opus": "audio/ogg"
        case "webm": "audio/webm"
        case "wav", "wave": "audio/wav"
        default: "application/octet-stream"
        }
    }
}

public struct DeepgramClient: Sendable {
    typealias Upload = @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)

    private let upload: Upload

    public init(session: URLSession = .shared) {
        upload = { request, audioURL in
            try await session.upload(for: request, fromFile: audioURL)
        }
    }

    init(upload: @escaping Upload) {
        self.upload = upload
    }

    public func transcribe(
        audioURL: URL,
        language: RecordingLanguage,
        apiKey: String,
        keyterms: [String] = []
    ) async throws -> Data {
        guard FileManager.default.isReadableFile(atPath: audioURL.path) else {
            throw DeepgramError.unreadableAudio
        }
        let request = try DeepgramRequestFactory.makeRequest(
            language: language,
            apiKey: apiKey,
            contentType: DeepgramRequestFactory.contentType(for: audioURL),
            keyterms: keyterms
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await upload(request, audioURL)
        } catch {
            throw DeepgramError.transport(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw DeepgramError.rejected(
                statusCode: httpResponse.statusCode,
                message: Self.safeErrorMessage(from: data)
            )
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw DeepgramError.invalidResponse
        }
        return data
    }

    private static func safeErrorMessage(from data: Data) -> String {
        struct APIError: Decodable {
            var errMsg: String?
            var message: String?

            enum CodingKeys: String, CodingKey {
                case errMsg = "err_msg"
                case message
            }
        }
        let decoded = try? JSONDecoder().decode(APIError.self, from: data)
        let message = decoded?.errMsg ?? decoded?.message ?? "Request rejected"
        return String(message.prefix(500))
    }

}
