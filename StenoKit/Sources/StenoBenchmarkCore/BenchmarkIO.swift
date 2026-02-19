import Foundation

public enum BenchmarkIOError: Error, LocalizedError {
    case missingFile(path: String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "Required file not found: \(path)"
        }
    }
}

public enum BenchmarkIO {
    public static func loadManifest(at path: String) throws -> BenchmarkManifest {
        try loadJSON(BenchmarkManifest.self, from: path)
    }

    public static func loadRawOutput(at path: String) throws -> RawEngineOutput {
        try loadJSON(RawEngineOutput.self, from: path)
    }

    public static func loadPipelineOutput(at path: String) throws -> PipelineOutput {
        try loadJSON(PipelineOutput.self, from: path)
    }

    public static func loadMacSanityChecklist(at path: String) throws -> MacSanityChecklist {
        try loadJSON(MacSanityChecklist.self, from: path)
    }

    public static func loadLexiconFile(at path: String) throws -> BenchmarkLexiconFile {
        try loadJSON(BenchmarkLexiconFile.self, from: path)
    }

    public static func saveRawOutput(_ output: RawEngineOutput, to path: String) throws {
        try saveJSON(output, to: path)
    }

    public static func savePipelineOutput(_ output: PipelineOutput, to path: String) throws {
        try saveJSON(output, to: path)
    }

    public static func saveMacSanityChecklist(_ output: MacSanityChecklist, to path: String) throws {
        try saveJSON(output, to: path)
    }

    public static func saveReport(_ markdown: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try ensureParentDirectory(for: url)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func saveJSON<Value: Encodable>(_ value: Value, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try ensureParentDirectory(for: url)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url)
    }

    private static func loadJSON<Value: Decodable>(_ type: Value.Type, from path: String) throws -> Value {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BenchmarkIOError.missingFile(path: path)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: data)
    }

    private static func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}
