import Foundation
import Testing

/// Fails when a test source file under StenoTests is not compiled into this bundle.
///
/// The Xcode project is generated from `project.yml`. A file added after the last
/// `xcodegen generate` is not in the project, so its tests silently never run while every other
/// suite still passes. This test lists the files on disk that declare a `@Test` and requires each
/// to be in the compiled test binary.
///
/// How a file is recognised in the binary: every `@Test` and `#expect` records its source
/// location, and the location's file ID ("StenoTests/HistoryTransitionTests.swift") is stored as
/// a string in the code compiled from that file. A file that was not compiled has none. The
/// check compares files, not suite names, because many files here hold free `@Test` functions
/// with no `@Suite`, and Swift Testing offers no public list of the tests it discovered.
@Suite("Test target coverage")
struct TestTargetCoverageTests {
    /// StenoTests, found from this file's own path, which is StenoTests/Transitions/.
    private static let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The Swift files under StenoTests that declare at least one test, by file ID.
    static func sourceFilesWithTests() throws -> Set<String> {
        let enumerator = try #require(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        var files = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let declaresTest = text.split(separator: "\n").contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("@Test")
            }
            if declaresTest { files.insert("StenoTests/" + url.lastPathComponent) }
        }
        return files
    }

    /// The file IDs stored in this bundle's executables: every NUL-ended string that starts
    /// with "StenoTests/".
    static func compiledFileIDs() throws -> Set<String> {
        let bundle = Bundle(for: BundleToken.self)
        let directory = try #require(bundle.executableURL).deletingLastPathComponent()
        let prefix = Data([0]) + Data("StenoTests/".utf8)
        var found = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            var start = data.startIndex
            while let match = data.range(of: prefix, in: start..<data.endIndex) {
                let begin = match.lowerBound + 1
                guard let end = data[begin...].firstIndex(of: 0) else { break }
                if end - begin < 200, let name = String(data: data[begin..<end], encoding: .utf8) { found.insert(name) }
                start = end
            }
        }
        return found
    }

    /// Whether the sources sit in a folder macOS guards per app (Desktop, Documents, Downloads).
    /// There each new test host would ask the person for access and hang until answered, so this
    /// check is left to CI and to the local QA gate, which compares declared and run test counts.
    static var sourcesNeedFolderAccess: Bool {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads"].contains { sourceRoot.path.hasPrefix(home + "/" + $0 + "/") }
    }

    @Test("Every test source file under StenoTests is compiled into the test bundle",
          .enabled(if: !sourcesNeedFolderAccess, "the sources are in a folder that would prompt for access"))
    func everyTestFileIsCompiled() throws {
        let onDisk = try Self.sourceFilesWithTests()
        #expect(onDisk.count > 50, "found only \(onDisk.count) test files under \(Self.sourceRoot.path)")
        let compiled = try Self.compiledFileIDs()
        #expect(compiled.contains("StenoTests/TestTargetCoverageTests.swift"), "the bundle's file IDs could not be read")
        let missing = onDisk.subtracting(compiled).sorted()
        #expect(missing.isEmpty, """
            These files declare tests but are not compiled into StenoTests: \(missing.joined(separator: ", ")). \
            Run xcodegen generate and build again.
            """)
    }
}

private final class BundleToken {}
