import Foundation
import Testing
@testable import StenoKit

@Test("RemoteCleanupEngine maps non-2xx and decoding failures")
func remoteCleanupEngineErrorMapping() async throws {
    RemoteProtocolState.box.set { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        let body = "service unavailable\n\(String(repeating: "y", count: 300))"
        return (response, Data(body.utf8))
    }

    let httpFailureEngine = RemoteCleanupEngine(
        config: .init(endpoint: URL(string: "https://example.com/cleanup")!, apiKey: "test-key"),
        urlSession: remoteTestSession()
    )

    do {
        _ = try await httpFailureEngine.cleanup(
            raw: RawTranscript(text: "raw"),
            profile: remoteTestStyleProfile(),
            lexicon: PersonalLexicon(entries: []),
            tier: .premium
        )
        Issue.record("Expected non-2xx response to throw RemoteCleanupError.httpFailure.")
    } catch RemoteCleanupError.httpFailure(let status, let bodyPreview) {
        #expect(status == 503)
        #expect(!bodyPreview.contains("\n"))
        #expect(bodyPreview.count <= 241)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    RemoteProtocolState.box.set { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data("not-json".utf8))
    }

    let decodeFailureEngine = RemoteCleanupEngine(
        config: .init(endpoint: URL(string: "https://example.com/cleanup")!, apiKey: "test-key"),
        urlSession: remoteTestSession()
    )

    do {
        _ = try await decodeFailureEngine.cleanup(
            raw: RawTranscript(text: "raw"),
            profile: remoteTestStyleProfile(),
            lexicon: PersonalLexicon(entries: []),
            tier: .economical
        )
        Issue.record("Expected invalid decode to throw RemoteCleanupError.decodingFailure.")
    } catch RemoteCleanupError.decodingFailure {
        // Expected.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func remoteTestSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RemoteURLProtocol.self]
    return URLSession(configuration: config)
}

private func remoteTestStyleProfile() -> StyleProfile {
    StyleProfile(
        name: "Test",
        tone: .natural,
        structureMode: .paragraph,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )
}

private enum RemoteProtocolState {
    static let box = RemoteHandlerBox()
}

private final class RemoteHandlerBox: @unchecked Sendable {
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

private final class RemoteURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = RemoteProtocolState.box.get() else {
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
