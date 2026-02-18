import Foundation
import Testing
@testable import StenoKit

@Test("OpenAICleanupEngine surfaces sanitized http failure and invalid content JSON")
func openAICleanupEngineErrorMapping() async throws {
    let longBody = """
    line-1
    \(String(repeating: "x", count: 400))
    """

    OpenAIProtocolState.box.set { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
        return (response, Data(longBody.utf8))
    }

    let httpFailureEngine = OpenAICleanupEngine(
        config: .init(apiKey: "test-key"),
        urlSession: openAITestSession()
    )

    do {
        _ = try await httpFailureEngine.cleanup(
            raw: RawTranscript(text: "hello"),
            profile: testStyleProfile(),
            lexicon: PersonalLexicon(entries: []),
            tier: .premium
        )
        Issue.record("Expected non-2xx response to throw OpenAICleanupError.httpFailure.")
    } catch OpenAICleanupError.httpFailure(let status, let bodyPreview) {
        #expect(status == 429)
        #expect(!bodyPreview.contains("\n"))
        #expect(bodyPreview.count <= 241)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let invalidPayloadResponse = """
    {"choices":[{"message":{"content":"not-json-content"}}]}
    """
    OpenAIProtocolState.box.set { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data(invalidPayloadResponse.utf8))
    }

    let invalidPayloadEngine = OpenAICleanupEngine(
        config: .init(apiKey: "test-key"),
        urlSession: openAITestSession()
    )

    do {
        _ = try await invalidPayloadEngine.cleanup(
            raw: RawTranscript(text: "hello"),
            profile: testStyleProfile(),
            lexicon: PersonalLexicon(entries: []),
            tier: .economical
        )
        Issue.record("Expected invalid payload JSON to throw OpenAICleanupError.invalidContentJSON.")
    } catch OpenAICleanupError.invalidContentJSON {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func openAITestSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OpenAIURLProtocol.self]
    return URLSession(configuration: config)
}

private func testStyleProfile() -> StyleProfile {
    StyleProfile(
        name: "Test",
        tone: .natural,
        structureMode: .paragraph,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )
}

private enum OpenAIProtocolState {
    static let box = OpenAIHandlerBox()
}

private final class OpenAIHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    func set(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func get() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

private final class OpenAIURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = OpenAIProtocolState.box.get() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
