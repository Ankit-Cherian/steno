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
        phoneticRecovery = try container.decodeIfPresent(PhoneticRecoveryPolicy.self, forKey: .phoneticRecovery) ?? .off
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

    /// Entries are sorted longest-term-first so longer multi-word phrases
    /// match before shorter substrings during lexicon application.
    public init(entries: [LexiconEntry] = []) {
        self.entries = entries.sorted {
            Self.sortKey(for: $0) > Self.sortKey(for: $1)
        }
    }

    private static func sortKey(for entry: LexiconEntry) -> Int {
        ([entry.term] + entry.aliases).map(\.count).max() ?? entry.term.count
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
}
