import Foundation

public enum RemoteCleanupError: Error, LocalizedError {
    case invalidResponse
    case insecureEndpoint(url: URL)
    case httpFailure(status: Int, bodyPreview: String)
    case decodingFailure

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Remote cleanup returned an invalid response"
        case .insecureEndpoint(let url):
            return "Remote cleanup endpoint must use HTTPS: \(url.absoluteString)"
        case .httpFailure(let status, let bodyPreview):
            return "Remote cleanup failed with status \(status): \(bodyPreview)"
        case .decodingFailure:
            return "Remote cleanup response could not be decoded"
        }
    }
}

public struct RemoteCleanupEngine: CleanupEngine, Sendable {
    public struct Configuration: Sendable {
        public var endpoint: URL
        public var apiKey: String
        public var premiumModel: String
        public var economicalModel: String

        public init(
            endpoint: URL,
            apiKey: String,
            premiumModel: String = "gpt-5-mini",
            economicalModel: String = "gpt-5-nano"
        ) {
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.premiumModel = premiumModel
            self.economicalModel = economicalModel
        }
    }

    private struct CleanupRequest: Codable {
        var model: String
        var instructions: String
        var transcript: String
        var tone: String
        var structure: String
        var fillerPolicy: String
        var commandPolicy: String
        var lexicon: [String: String]
    }

    private struct CleanupResponse: Codable {
        var text: String
        var edits: [TranscriptEdit]?
        var removedFillers: [String]?
        var uncertaintyFlags: [String]?
    }

    private let config: Configuration
    private let urlSession: URLSession

    public init(config: Configuration, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    public func cleanup(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        tier: CloudModelTier
    ) async throws -> CleanTranscript {
        guard config.endpoint.scheme?.lowercased() == "https" else {
            throw RemoteCleanupError.insecureEndpoint(url: config.endpoint)
        }

        let requestBody = CleanupRequest(
            model: model(for: tier),
            instructions: "Rewrite for clarity. Remove fillers per policy. Preserve user intent exactly. Do not add new facts.",
            transcript: raw.text,
            tone: profile.tone.rawValue,
            structure: profile.structureMode.rawValue,
            fillerPolicy: profile.fillerPolicy.rawValue,
            commandPolicy: profile.commandPolicy.rawValue,
            lexicon: lexiconMap(from: lexicon)
        )

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteCleanupError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RemoteCleanupError.httpFailure(
                status: httpResponse.statusCode,
                bodyPreview: sanitizeErrorBodyPreview(body)
            )
        }

        let decoded: CleanupResponse
        do {
            decoded = try JSONDecoder().decode(CleanupResponse.self, from: data)
        } catch {
            StenoKitDiagnostics.logger.error(
                "Remote cleanup response decode failed: \(error.localizedDescription, privacy: .public)"
            )
            throw RemoteCleanupError.decodingFailure
        }

        return CleanTranscript(
            text: decoded.text,
            edits: decoded.edits ?? [],
            removedFillers: decoded.removedFillers ?? [],
            uncertaintyFlags: decoded.uncertaintyFlags ?? [],
            modelTier: tier
        )
    }

    private func sanitizeErrorBodyPreview(_ body: String) -> String {
        let cleaned = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return "(no response body)"
        }
        let limit = 240
        if cleaned.count <= limit {
            return cleaned
        }
        let cutoff = cleaned.index(cleaned.startIndex, offsetBy: limit)
        return "\(cleaned[..<cutoff])…"
    }

    private func lexiconMap(from lexicon: PersonalLexicon) -> [String: String] {
        // Last-write-wins avoids crashes when duplicate terms exist in user data.
        var map: [String: String] = [:]
        map.reserveCapacity(lexicon.entries.count)
        for entry in lexicon.entries {
            map[entry.term] = entry.preferred
        }
        return map
    }

    private func model(for tier: CloudModelTier) -> String {
        switch tier {
        case .premium:
            return config.premiumModel
        case .economical:
            return config.economicalModel
        case .none:
            return config.economicalModel
        }
    }
}
