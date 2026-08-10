import Foundation

public enum UsageDurationQuality: String, Codable, Sendable, Equatable {
    case captureExact
    case transcriptEstimate
    case unavailable
}

public enum UsageMetricQuality: String, Codable, Sendable, Equatable {
    case exact
    case estimated
}

public struct UsageCleanupBreakdown: Codable, Sendable, Equatable {
    public var fillerRemovals: Int
    public var lexiconCorrections: Int
    public var repairResolutions: Int
    public var structureRewrites: Int
    public var punctuationChanges: Int
    public var commandTransforms: Int
    public var estimatedWordChanges: Int

    public init(
        fillerRemovals: Int = 0,
        lexiconCorrections: Int = 0,
        repairResolutions: Int = 0,
        structureRewrites: Int = 0,
        punctuationChanges: Int = 0,
        commandTransforms: Int = 0,
        estimatedWordChanges: Int = 0
    ) {
        self.fillerRemovals = max(0, fillerRemovals)
        self.lexiconCorrections = max(0, lexiconCorrections)
        self.repairResolutions = max(0, repairResolutions)
        self.structureRewrites = max(0, structureRewrites)
        self.punctuationChanges = max(0, punctuationChanges)
        self.commandTransforms = max(0, commandTransforms)
        self.estimatedWordChanges = max(0, estimatedWordChanges)
    }

    public static let zero = UsageCleanupBreakdown()

    public var total: Int {
        fillerRemovals
            + lexiconCorrections
            + repairResolutions
            + structureRewrites
            + punctuationChanges
            + commandTransforms
            + estimatedWordChanges
    }

    public func adding(_ other: UsageCleanupBreakdown) -> UsageCleanupBreakdown {
        UsageCleanupBreakdown(
            fillerRemovals: fillerRemovals + other.fillerRemovals,
            lexiconCorrections: lexiconCorrections + other.lexiconCorrections,
            repairResolutions: repairResolutions + other.repairResolutions,
            structureRewrites: structureRewrites + other.structureRewrites,
            punctuationChanges: punctuationChanges + other.punctuationChanges,
            commandTransforms: commandTransforms + other.commandTransforms,
            estimatedWordChanges: estimatedWordChanges + other.estimatedWordChanges
        )
    }

    public static func exact(edits: [TranscriptEdit]) -> UsageCleanupBreakdown {
        var result = UsageCleanupBreakdown.zero
        for edit in edits {
            switch edit.kind {
            case .fillerRemoval:
                result.fillerRemovals += 1
            case .lexiconCorrection:
                result.lexiconCorrections += 1
            case .repairResolution:
                result.repairResolutions += 1
            case .structureRewrite:
                result.structureRewrites += 1
            case .punctuation:
                result.punctuationChanges += 1
            case .commandTransform:
                result.commandTransforms += 1
            }
        }
        return result
    }
}

public struct UsageEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var appBundleID: String
    public var rawWordCount: Int
    public var finalWordCount: Int
    public var durationMS: Int
    public var durationQuality: UsageDurationQuality
    public var cleanupChanges: UsageCleanupBreakdown
    public var cleanupQuality: UsageMetricQuality
    public var insertionStatus: InsertionStatus

    public init(
        id: UUID,
        createdAt: Date,
        appBundleID: String,
        rawWordCount: Int,
        finalWordCount: Int,
        durationMS: Int,
        durationQuality: UsageDurationQuality,
        cleanupChanges: UsageCleanupBreakdown,
        cleanupQuality: UsageMetricQuality,
        insertionStatus: InsertionStatus
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appBundleID = appBundleID.isEmpty ? "unknown" : appBundleID
        self.rawWordCount = max(0, rawWordCount)
        self.finalWordCount = max(0, finalWordCount)
        self.durationMS = max(0, durationMS)
        self.durationQuality = durationMS > 0 ? durationQuality : .unavailable
        self.cleanupChanges = cleanupChanges
        self.cleanupQuality = cleanupQuality
        self.insertionStatus = insertionStatus
    }

    public static func live(
        from entry: TranscriptEntry,
        captureDurationMS: Int,
        edits: [TranscriptEdit],
        spokenText: String? = nil
    ) -> UsageEvent {
        let resolvedDuration = max(0, captureDurationMS)
        let finalText = resolvedFinalText(for: entry)
        let dictatedText = spokenText ?? entry.rawText
        return UsageEvent(
            id: entry.id,
            createdAt: entry.createdAt,
            appBundleID: entry.appBundleID,
            rawWordCount: wordTokens(in: dictatedText).count,
            finalWordCount: wordTokens(in: finalText).count,
            durationMS: resolvedDuration,
            durationQuality: resolvedDuration > 0 ? .captureExact : .unavailable,
            cleanupChanges: .exact(edits: edits),
            cleanupQuality: .exact,
            insertionStatus: entry.insertionStatus
        )
    }

    public static func backfilled(from entry: TranscriptEntry) -> UsageEvent {
        backfilled(
            id: entry.id,
            createdAt: entry.createdAt,
            appBundleID: entry.appBundleID,
            rawText: entry.rawText,
            cleanText: entry.cleanText,
            durationMS: entry.durationMS,
            insertionStatus: entry.insertionStatus
        )
    }

    static func backfilled(
        id: UUID,
        createdAt: Date,
        appBundleID: String,
        rawText: String,
        cleanText: String,
        durationMS: Int?,
        insertionStatus: InsertionStatus
    ) -> UsageEvent {
        let rawTokens = wordTokens(in: rawText)
        let finalText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rawText
            : cleanText
        let finalTokens = wordTokens(in: finalText)
        let rawCleanupTokens = cleanupTokens(in: rawText)
        let finalCleanupTokens = cleanupTokens(in: finalText)
        let resolvedDuration = max(0, durationMS ?? 0)
        return UsageEvent(
            id: id,
            createdAt: createdAt,
            appBundleID: appBundleID,
            rawWordCount: rawTokens.count,
            finalWordCount: finalTokens.count,
            durationMS: resolvedDuration,
            durationQuality: resolvedDuration > 0 ? .transcriptEstimate : .unavailable,
            cleanupChanges: UsageCleanupBreakdown(
                estimatedWordChanges: tokenEditDistance(
                    from: rawCleanupTokens,
                    to: finalCleanupTokens
                )
            ),
            cleanupQuality: .estimated,
            insertionStatus: insertionStatus
        )
    }

    private static func resolvedFinalText(for entry: TranscriptEntry) -> String {
        entry.cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? entry.rawText
            : entry.cleanText
    }

    private static func wordTokens(in text: String) -> [String] {
        text.lowercased()
            .split { character in
                !character.isLetter && !character.isNumber && !isWordApostrophe(character)
            }
            .map(String.init)
    }

    private static func cleanupTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var currentWord = ""

        func appendCurrentWord() {
            guard !currentWord.isEmpty else { return }
            tokens.append(currentWord)
            currentWord.removeAll(keepingCapacity: true)
        }

        for character in text {
            if character.isLetter || character.isNumber || isWordApostrophe(character) {
                currentWord.append(character)
            } else {
                appendCurrentWord()
                if !character.isWhitespace {
                    tokens.append(String(character))
                }
            }
        }
        appendCurrentWord()
        return tokens
    }

    private static func isWordApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }

    private static func tokenEditDistance(from source: [String], to destination: [String]) -> Int {
        guard !source.isEmpty else { return destination.count }
        guard !destination.isEmpty else { return source.count }

        var previous = Array(0...destination.count)
        for (sourceIndex, sourceToken) in source.enumerated() {
            var current = Array(repeating: 0, count: destination.count + 1)
            current[0] = sourceIndex + 1
            for (destinationIndex, destinationToken) in destination.enumerated() {
                let substitutionCost = sourceToken == destinationToken ? 0 : 1
                current[destinationIndex + 1] = min(
                    current[destinationIndex] + 1,
                    previous[destinationIndex + 1] + 1,
                    previous[destinationIndex] + substitutionCost
                )
            }
            previous = current
        }
        return previous[destination.count]
    }
}

public struct UsageCoverageInterval: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date?

    public init(start: Date, end: Date?) {
        self.start = start
        self.end = end
    }
}

public struct DailyUsage: Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var sessionCount: Int
    public var wordCount: Int
    public var durationMS: Int
    public var cleanupChanges: Int
    public var estimatedDurationSessionCount: Int
    public var unavailableDurationSessionCount: Int
    public var isTracked: Bool
    public var isActive: Bool
    public var isInCurrentStreak: Bool

    public init(
        date: Date,
        sessionCount: Int,
        wordCount: Int,
        durationMS: Int,
        cleanupChanges: Int,
        estimatedDurationSessionCount: Int,
        unavailableDurationSessionCount: Int,
        isTracked: Bool,
        isActive: Bool,
        isInCurrentStreak: Bool
    ) {
        self.date = date
        self.sessionCount = sessionCount
        self.wordCount = wordCount
        self.durationMS = durationMS
        self.cleanupChanges = cleanupChanges
        self.estimatedDurationSessionCount = estimatedDurationSessionCount
        self.unavailableDurationSessionCount = unavailableDurationSessionCount
        self.isTracked = isTracked
        self.isActive = isActive
        self.isInCurrentStreak = isInCurrentStreak
    }
}

public struct AppUsageSummary: Sendable, Equatable, Identifiable {
    public var id: String { appBundleID }
    public var appBundleID: String
    public var sessionCount: Int
    public var wordCount: Int
    public var durationMS: Int
    public var estimatedDurationSessionCount: Int
    public var unavailableDurationSessionCount: Int

    public init(
        appBundleID: String,
        sessionCount: Int,
        wordCount: Int,
        durationMS: Int,
        estimatedDurationSessionCount: Int,
        unavailableDurationSessionCount: Int
    ) {
        self.appBundleID = appBundleID
        self.sessionCount = sessionCount
        self.wordCount = wordCount
        self.durationMS = durationMS
        self.estimatedDurationSessionCount = estimatedDurationSessionCount
        self.unavailableDurationSessionCount = unavailableDurationSessionCount
    }
}

public struct UsageAnalyticsSnapshot: Sendable, Equatable {
    public var totalSessions: Int
    public var totalWords: Int
    public var totalDurationMS: Int
    public var averageWordsPerMinute: Double
    public var activeDayCount: Int
    public var currentStreak: Int
    public var longestKnownStreak: Int
    public var cleanupChanges: UsageCleanupBreakdown
    public var exactCleanupSessionCount: Int
    public var estimatedCleanupSessionCount: Int
    public var exactDurationSessionCount: Int
    public var estimatedDurationSessionCount: Int
    public var unavailableDurationSessionCount: Int
    public var topApps: [AppUsageSummary]
    public var dailyUsage: [DailyUsage]
    public var coverage: [UsageCoverageInterval]

    public init(
        totalSessions: Int,
        totalWords: Int,
        totalDurationMS: Int,
        averageWordsPerMinute: Double,
        activeDayCount: Int,
        currentStreak: Int,
        longestKnownStreak: Int,
        cleanupChanges: UsageCleanupBreakdown,
        exactCleanupSessionCount: Int,
        estimatedCleanupSessionCount: Int,
        exactDurationSessionCount: Int,
        estimatedDurationSessionCount: Int,
        unavailableDurationSessionCount: Int,
        topApps: [AppUsageSummary],
        dailyUsage: [DailyUsage],
        coverage: [UsageCoverageInterval]
    ) {
        self.totalSessions = totalSessions
        self.totalWords = totalWords
        self.totalDurationMS = totalDurationMS
        self.averageWordsPerMinute = averageWordsPerMinute
        self.activeDayCount = activeDayCount
        self.currentStreak = currentStreak
        self.longestKnownStreak = longestKnownStreak
        self.cleanupChanges = cleanupChanges
        self.exactCleanupSessionCount = exactCleanupSessionCount
        self.estimatedCleanupSessionCount = estimatedCleanupSessionCount
        self.exactDurationSessionCount = exactDurationSessionCount
        self.estimatedDurationSessionCount = estimatedDurationSessionCount
        self.unavailableDurationSessionCount = unavailableDurationSessionCount
        self.topApps = topApps
        self.dailyUsage = dailyUsage
        self.coverage = coverage
    }

    public static let empty = UsageAnalyticsSnapshot(
        totalSessions: 0,
        totalWords: 0,
        totalDurationMS: 0,
        averageWordsPerMinute: 0,
        activeDayCount: 0,
        currentStreak: 0,
        longestKnownStreak: 0,
        cleanupChanges: .zero,
        exactCleanupSessionCount: 0,
        estimatedCleanupSessionCount: 0,
        exactDurationSessionCount: 0,
        estimatedDurationSessionCount: 0,
        unavailableDurationSessionCount: 0,
        topApps: [],
        dailyUsage: [],
        coverage: []
    )
}

public enum UsageAnalyticsCalculator {
    public static func snapshot(
        events: [UsageEvent],
        coverage: [UsageCoverageInterval],
        now: Date = Date(),
        calendar: Calendar = .current,
        months: Int = 6
    ) -> UsageAnalyticsSnapshot {
        let requestedMonths = max(1, months)
        let today = calendar.startOfDay(for: now)
        let currentMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let windowStart = calendar.date(
            byAdding: .month,
            value: -(requestedMonths - 1),
            to: currentMonth
        ) ?? currentMonth
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let allEvents = events.filter { $0.createdAt < windowEnd }
        let windowEvents = allEvents.filter {
            $0.createdAt >= windowStart && $0.createdAt < windowEnd
        }

        let groupedByDay = Dictionary(grouping: windowEvents) {
            calendar.startOfDay(for: $0.createdAt)
        }
        let activeDays = Set(allEvents.map { calendar.startOfDay(for: $0.createdAt) })
        let currentStreakDays = currentStreakDates(
            activeDays: activeDays,
            today: today,
            calendar: calendar
        )

        var dailyUsage: [DailyUsage] = []
        var cursor = windowStart
        while cursor <= today {
            let eventsForDay = groupedByDay[cursor] ?? []
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            let isCovered = coverage.contains { interval in
                let intervalEnd = interval.end ?? .distantFuture
                return interval.start < dayEnd && intervalEnd >= cursor
            }
            dailyUsage.append(
                DailyUsage(
                    date: cursor,
                    sessionCount: eventsForDay.count,
                    wordCount: eventsForDay.reduce(0) { $0 + $1.rawWordCount },
                    durationMS: eventsForDay.reduce(0) { $0 + $1.durationMS },
                    cleanupChanges: eventsForDay.reduce(0) { $0 + $1.cleanupChanges.total },
                    estimatedDurationSessionCount: eventsForDay.filter {
                        $0.durationQuality == .transcriptEstimate
                    }.count,
                    unavailableDurationSessionCount: eventsForDay.filter {
                        $0.durationQuality == .unavailable
                    }.count,
                    isTracked: isCovered || !eventsForDay.isEmpty,
                    isActive: !eventsForDay.isEmpty,
                    isInCurrentStreak: currentStreakDays.contains(cursor)
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else {
                break
            }
            cursor = next
        }

        let appGroups = Dictionary(grouping: allEvents, by: \UsageEvent.appBundleID)
        let topApps = appGroups.map { bundleID, appEvents in
            AppUsageSummary(
                appBundleID: bundleID,
                sessionCount: appEvents.count,
                wordCount: appEvents.reduce(0) { $0 + $1.rawWordCount },
                durationMS: appEvents.reduce(0) { $0 + $1.durationMS },
                estimatedDurationSessionCount: appEvents.filter {
                    $0.durationQuality == .transcriptEstimate
                }.count,
                unavailableDurationSessionCount: appEvents.filter {
                    $0.durationQuality == .unavailable
                }.count
            )
        }
        .sorted {
            if $0.sessionCount != $1.sessionCount { return $0.sessionCount > $1.sessionCount }
            if $0.durationMS != $1.durationMS { return $0.durationMS > $1.durationMS }
            if $0.wordCount != $1.wordCount { return $0.wordCount > $1.wordCount }
            return $0.appBundleID.localizedStandardCompare($1.appBundleID) == .orderedAscending
        }

        let durationEvents = allEvents.filter { $0.durationMS > 0 }
        let durationMS = durationEvents.reduce(0) { $0 + $1.durationMS }
        let durationWords = durationEvents.reduce(0) { $0 + $1.rawWordCount }
        let averageWPM = durationMS > 0
            ? Double(durationWords) / (Double(durationMS) / 60_000)
            : 0
        let cleanup = allEvents.reduce(UsageCleanupBreakdown.zero) {
            $0.adding($1.cleanupChanges)
        }

        return UsageAnalyticsSnapshot(
            totalSessions: allEvents.count,
            totalWords: allEvents.reduce(0) { $0 + $1.rawWordCount },
            totalDurationMS: durationMS,
            averageWordsPerMinute: averageWPM,
            activeDayCount: activeDays.count,
            currentStreak: currentStreakDays.count,
            longestKnownStreak: longestStreak(
                activeDays: activeDays,
                calendar: calendar
            ),
            cleanupChanges: cleanup,
            exactCleanupSessionCount: allEvents.filter { $0.cleanupQuality == .exact }.count,
            estimatedCleanupSessionCount: allEvents.filter { $0.cleanupQuality == .estimated }.count,
            exactDurationSessionCount: allEvents.filter { $0.durationQuality == .captureExact }.count,
            estimatedDurationSessionCount: allEvents.filter {
                $0.durationQuality == .transcriptEstimate
            }.count,
            unavailableDurationSessionCount: allEvents.filter { $0.durationQuality == .unavailable }.count,
            topApps: topApps,
            dailyUsage: dailyUsage,
            coverage: coverage.sorted { $0.start < $1.start }
        )
    }

    private static func currentStreakDates(
        activeDays: Set<Date>,
        today: Date,
        calendar: Calendar
    ) -> Set<Date> {
        var cursor = today
        if !activeDays.contains(cursor),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
           activeDays.contains(yesterday) {
            cursor = yesterday
        }

        var result: Set<Date> = []
        while activeDays.contains(cursor) {
            result.insert(cursor)
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return result
    }

    private static func longestStreak(activeDays: Set<Date>, calendar: Calendar) -> Int {
        var longest = 0
        var current = 0
        var previous: Date?
        for day in activeDays.sorted() {
            if let previous,
               let expected = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(day, inSameDayAs: expected) {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
            previous = day
        }
        return longest
    }
}
