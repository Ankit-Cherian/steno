import Foundation

public enum StyleTone: String, Sendable, Codable, Equatable, CaseIterable {
    case natural
    case professional
    case concise
    case friendly
    case technical
}

public enum StructureMode: String, Sendable, Codable, Equatable, CaseIterable {
    case natural
    case paragraph
    case bullets
    case email
    case command
}

public enum FillerPolicy: String, Sendable, Codable, Equatable, CaseIterable {
    case minimal
    case balanced
    case aggressive
}

public enum CommandPolicy: String, Sendable, Codable, Equatable, CaseIterable {
    case passthrough
    case transform
}

public struct StyleProfile: Sendable, Codable, Equatable {
    public var name: String
    public var tone: StyleTone
    public var structureMode: StructureMode
    public var fillerPolicy: FillerPolicy
    public var commandPolicy: CommandPolicy

    public init(
        name: String,
        tone: StyleTone,
        structureMode: StructureMode,
        fillerPolicy: FillerPolicy,
        commandPolicy: CommandPolicy
    ) {
        self.name = name
        self.tone = tone
        self.structureMode = structureMode
        self.fillerPolicy = fillerPolicy
        self.commandPolicy = commandPolicy
    }

    /// A style value written by a newer version falls back to the least
    /// transforming choice instead of discarding the profile.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        tone = try container.decodeLenientlyIfPresent(StyleTone.self, forKey: .tone, fallback: .natural) ?? .natural
        structureMode = try container.decodeLenientlyIfPresent(
            StructureMode.self,
            forKey: .structureMode,
            fallback: .natural
        ) ?? .natural
        fillerPolicy = try container.decodeLenientlyIfPresent(
            FillerPolicy.self,
            forKey: .fillerPolicy,
            fallback: .balanced
        ) ?? .balanced
        commandPolicy = try container.decodeLenientlyIfPresent(
            CommandPolicy.self,
            forKey: .commandPolicy,
            fallback: .transform
        ) ?? .transform
    }
}

public enum Scope: Sendable, Codable, Equatable {
    case global
    case app(bundleID: String)
}

public enum PhoneticRecoveryPolicy: String, Sendable, Codable, Equatable, CaseIterable {
    case off
    case properNounEnglish
}

public struct LexiconEntry: Sendable, Codable, Equatable {
    public var term: String
    public var preferred: String
    public var scope: Scope
    public var aliases: [String] = []
    public var phoneticRecovery: PhoneticRecoveryPolicy = .off

    public init(
        term: String,
        preferred: String,
        scope: Scope,
        aliases: [String] = [],
        phoneticRecovery: PhoneticRecoveryPolicy = .off
    ) {
        self.term = term
        self.preferred = preferred
        self.scope = scope
        self.aliases = aliases
        self.phoneticRecovery = phoneticRecovery
    }

    public init(term: String, preferred: String, scope: Scope, aliases: [String]) {
        self.init(
            term: term,
            preferred: preferred,
            scope: scope,
            aliases: aliases,
            phoneticRecovery: .off
        )
    }

    enum CodingKeys: String, CodingKey {
        case term
        case preferred
        case scope
        case aliases
        case phoneticRecovery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        term = try container.decode(String.self, forKey: .term)
        preferred = try container.decode(String.self, forKey: .preferred)
        scope = try container.decode(Scope.self, forKey: .scope)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        phoneticRecovery = try container.decodeLenientlyIfPresent(
            PhoneticRecoveryPolicy.self,
            forKey: .phoneticRecovery,
            fallback: .off
        ) ?? .off
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(term, forKey: .term)
        try container.encode(preferred, forKey: .preferred)
        try container.encode(scope, forKey: .scope)
        if aliases.isEmpty == false {
            try container.encode(aliases, forKey: .aliases)
        }
        if phoneticRecovery != .off {
            try container.encode(phoneticRecovery, forKey: .phoneticRecovery)
        }
    }
}

public struct PersonalLexicon: Sendable, Codable, Equatable {
    public var entries: [LexiconEntry]

    /// Entries are sorted longest-term-first; entries of equal length keep their saved order,
    /// which decides between duplicate terms.
    public init(entries: [LexiconEntry] = []) {
        self.entries = Self.longestFirst(entries)
    }

    static func longestFirst(_ entries: [LexiconEntry]) -> [LexiconEntry] {
        entries.enumerated()
            .sorted { lhs, rhs in
                let lhsKey = sortKey(for: lhs.element)
                let rhsKey = sortKey(for: rhs.element)
                return lhsKey != rhsKey ? lhsKey > rhsKey : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func sortKey(for entry: LexiconEntry) -> Int {
        ([entry.term] + entry.aliases)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ").count }
            .max() ?? 0
    }
}

public struct Snippet: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var expansion: String
    public var scope: Scope

    public init(id: UUID = UUID(), trigger: String, expansion: String, scope: Scope = .global) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.scope = scope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try container.decode(String.self, forKey: .trigger)
        expansion = try container.decode(String.self, forKey: .expansion)
        scope = try container.decodeIfPresent(Scope.self, forKey: .scope) ?? .global
    }
}
