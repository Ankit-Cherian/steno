import CryptoKit
import Foundation

public struct BenchmarkSourceIdentity: Sendable, Codable, Equatable {
    public var commitSHA: String?
    public var treeIsDirty: Bool?

    public init(commitSHA: String? = nil, treeIsDirty: Bool? = nil) {
        self.commitSHA = commitSHA
        self.treeIsDirty = treeIsDirty
    }
}

public struct BenchmarkArtifactIdentity: Sendable, Codable, Equatable {
    public var appCommitSHA: String?
    public var appTreeIsDirty: Bool?
    public var engineCommitSHA: String?
    public var manifestSHA256: String?
    public var audioSetSHA256: String?
    public var whisperCLISHA256: String?
    public var modelSHA256: String?
    public var vadModelSHA256: String?

    public init(
        appCommitSHA: String? = nil,
        appTreeIsDirty: Bool? = nil,
        engineCommitSHA: String? = nil,
        manifestSHA256: String? = nil,
        audioSetSHA256: String? = nil,
        whisperCLISHA256: String? = nil,
        modelSHA256: String? = nil,
        vadModelSHA256: String? = nil
    ) {
        self.appCommitSHA = appCommitSHA
        self.appTreeIsDirty = appTreeIsDirty
        self.engineCommitSHA = engineCommitSHA
        self.manifestSHA256 = manifestSHA256
        self.audioSetSHA256 = audioSetSHA256
        self.whisperCLISHA256 = whisperCLISHA256
        self.modelSHA256 = modelSHA256
        self.vadModelSHA256 = vadModelSHA256
    }

    public static func capture(
        manifest: BenchmarkManifest,
        manifestPath: String,
        whisperConfiguration: BenchmarkWhisperConfiguration,
        appSourceIdentity: BenchmarkSourceIdentity? = nil,
        engineSourceIdentity: BenchmarkSourceIdentity? = nil
    ) -> BenchmarkArtifactIdentity {
        let manifestURL = absoluteFileURL(for: manifestPath)
        let whisperCLIURL = absoluteFileURL(for: whisperConfiguration.whisperCLIPath)
        let modelURL = absoluteFileURL(for: whisperConfiguration.modelPath)
        let resolvedAppSource = appSourceIdentity
            ?? sourceIdentity(startingAt: manifestURL)
        let resolvedEngineSource = engineSourceIdentity
            ?? sourceIdentity(startingAt: whisperCLIURL)

        return BenchmarkArtifactIdentity(
            appCommitSHA: resolvedAppSource.commitSHA,
            appTreeIsDirty: resolvedAppSource.treeIsDirty,
            engineCommitSHA: resolvedEngineSource.commitSHA,
            manifestSHA256: sha256(of: manifestURL),
            audioSetSHA256: audioSetSHA256(
                manifest: manifest,
                manifestDirectory: manifestURL.deletingLastPathComponent()
            ),
            whisperCLISHA256: sha256(of: whisperCLIURL),
            modelSHA256: sha256(of: modelURL),
            vadModelSHA256: vadModelPath(in: whisperConfiguration.additionalArguments)
                .map { sha256(of: absoluteFileURL(for: $0)) } ?? nil
        )
    }

    private static func audioSetSHA256(
        manifest: BenchmarkManifest,
        manifestDirectory: URL
    ) -> String? {
        var hasher = SHA256()

        for sample in manifest.samples {
            let audioURL: URL
            if sample.audioPath.hasPrefix("/") {
                audioURL = URL(fileURLWithPath: sample.audioPath)
            } else {
                audioURL = manifestDirectory.appendingPathComponent(sample.audioPath)
            }
            guard let audioSHA256 = sha256(of: audioURL) else {
                return nil
            }

            hasher.update(data: Data(sample.id.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(sample.audioPath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(audioSHA256.utf8))
            hasher.update(data: Data([0]))
        }

        return hexDigest(hasher.finalize())
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hexDigest(hasher.finalize())
    }

    private static func hexDigest<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func vadModelPath(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--vad-model", arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
            if argument.hasPrefix("--vad-model=") {
                return String(argument.dropFirst("--vad-model=".count))
            }
        }
        return nil
    }

    private static func sourceIdentity(startingAt url: URL) -> BenchmarkSourceIdentity {
        guard let root = repositoryRoot(startingAt: url) else {
            return BenchmarkSourceIdentity()
        }

        let commitSHA = runGit(["rev-parse", "HEAD"], repositoryRoot: root)
        let status = runGit(["status", "--porcelain", "--untracked-files=all"], repositoryRoot: root)
        return BenchmarkSourceIdentity(
            commitSHA: commitSHA.flatMap { $0.isEmpty ? nil : $0 },
            treeIsDirty: status.map { !$0.isEmpty }
        )
    }

    private static func repositoryRoot(startingAt url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            candidate.deleteLastPathComponent()
        }

        while true {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(".git").path
            ) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }

    private static func runGit(_ arguments: [String], repositoryRoot: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryRoot.path] + arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func absoluteFileURL(for path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(path)
            .standardizedFileURL
    }
}
