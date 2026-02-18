import Foundation

public enum OpenAICleanupError: Error, LocalizedError {
    case invalidResponse
    case insecureEndpoint(url: URL)
    case httpFailure(status: Int, bodyPreview: String)
    case missingContent
    case invalidContentJSON

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenAI cleanup returned an invalid response"
        case .insecureEndpoint(let url):
            return "OpenAI cleanup endpoint must use HTTPS: \(url.absoluteString)"
        case .httpFailure(let status, let bodyPreview):
            return "OpenAI cleanup failed with status \(status): \(bodyPreview)"
        case .missingContent:
            return "OpenAI cleanup returned no content"
        case .invalidContentJSON:
            return "OpenAI cleanup content was not valid JSON"
        }
    }
}

public struct OpenAICleanupEngine: CleanupEngine, Sendable {
    public struct Configuration: Sendable {
        public var apiKey: String
        public var premiumModel: String
        public var economicalModel: String
        public var endpoint: URL

        public init(
            apiKey: String,
            premiumModel: String = "gpt-5-mini",
            economicalModel: String = "gpt-5-nano",
            endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!
        ) {
            self.apiKey = apiKey
            self.premiumModel = premiumModel
            self.economicalModel = economicalModel
            self.endpoint = endpoint
        }
    }

    private struct ChatRequest: Codable {
        struct Message: Codable {
            var role: String
            var content: String
        }

        struct ResponseFormat: Codable {
            var type: String
        }

        var model: String
        var messages: [Message]
        var response_format: ResponseFormat
        var temperature: Double
    }

    private struct ChatResponse: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                var content: String
            }

            var message: Message
        }

        var choices: [Choice]
    }

    private struct CleanPayload: Codable {
        var text: String
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
            throw OpenAICleanupError.insecureEndpoint(url: config.endpoint)
        }

        let model = tier == .economical ? config.economicalModel : config.premiumModel

        let lexiconLines = lexicon.entries.map { "- \($0.term) => \($0.preferred)" }.joined(separator: "\n")
        let userPrompt = """
        Transcript:
        \(raw.text)

        Style Profile:
        - tone: \(profile.tone.rawValue)
        - structure: \(profile.structureMode.rawValue)
        - fillerPolicy: \(profile.fillerPolicy.rawValue)
        - commandPolicy: \(profile.commandPolicy.rawValue)

        Lexicon corrections:
        \(lexiconLines.isEmpty ? "(none)" : lexiconLines)
        """

        let systemPrompt = """
        You are a transcript cleanup engine.
        Goals:
        1) Remove filler words according to filler policy.
        2) Rewrite for clarity while preserving meaning exactly.
        3) Apply lexicon corrections exactly.
        4) Do not invent facts.

        Return strict JSON with keys:
        - text: string
        - removedFillers: string[]
        - uncertaintyFlags: string[]
        """

        let requestBody = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            response_format: .init(type: "json_object"),
            temperature: 0.2
        )

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICleanupError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICleanupError.httpFailure(
                status: httpResponse.statusCode,
                bodyPreview: sanitizeErrorBodyPreview(body)
            )
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chatResponse.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAICleanupError.missingContent
        }

        guard let payloadData = content.data(using: .utf8) else {
            throw OpenAICleanupError.invalidContentJSON
        }

        let payload: CleanPayload
        do {
            payload = try JSONDecoder().decode(CleanPayload.self, from: payloadData)
        } catch {
            StenoKitDiagnostics.logger.error(
                "OpenAI cleanup payload decode failed: \(error.localizedDescription, privacy: .public)"
            )
            throw OpenAICleanupError.invalidContentJSON
        }

        return CleanTranscript(
            text: payload.text,
            edits: [],
            removedFillers: payload.removedFillers ?? [],
            uncertaintyFlags: payload.uncertaintyFlags ?? [],
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
}
