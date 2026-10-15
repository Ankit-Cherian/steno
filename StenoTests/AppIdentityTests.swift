import Foundation
import Testing
@testable import Steno

@Suite("The app chooser's answer")
@MainActor
struct AppIdentityTests {
    private func makeBundle(identifier: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoAppIdentityTests-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleName": "Fixture", "CFBundlePackageType": "APPL"]
        if let identifier { info["CFBundleIdentifier"] = identifier }
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    @Test("A cancelled panel is a cancellation, an app without an identifier is not")
    func cancelledAndNoIdentifierAreDifferent() throws {
        #expect(AppIdentity.choice(forChosenAppAt: nil) == .cancelled)

        let anonymous = try makeBundle(identifier: nil)
        defer { try? FileManager.default.removeItem(at: anonymous.deletingLastPathComponent()) }
        #expect(AppIdentity.choice(forChosenAppAt: anonymous) == .noIdentifier)

        let empty = try makeBundle(identifier: "")
        defer { try? FileManager.default.removeItem(at: empty.deletingLastPathComponent()) }
        #expect(AppIdentity.choice(forChosenAppAt: empty) == .noIdentifier)

        let missing = URL(fileURLWithPath: "/nonexistent/Nothing.app")
        #expect(AppIdentity.choice(forChosenAppAt: missing) == .noIdentifier)
    }

    @Test("An app with an identifier is chosen by it")
    func appWithIdentifier() throws {
        let app = try makeBundle(identifier: "com.example.steno-fixture")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(AppIdentity.choice(forChosenAppAt: app) == .app("com.example.steno-fixture"))
    }
}
