#if DEBUG
import Foundation
import StenoKit

/// Sample dictations, step records and usage for isolated previews and render tests. Nothing
/// here reads or writes the person's History, Settings or Insights.
@MainActor
enum WindowSampleData {
    static let latestText = "Move the planning meeting from Thursday to Friday. Send the updated agenda to Dana before lunch so everyone has time to read it."
    static let latestRaw = "Um, move the planning meeting from Thursday to Friday. Send the updated agenda to Dana before lunch so everyone has time to read it"
    static let groceries = "Pick up tomatoes, pasta, olive oil, and a loaf of bread. Check whether we need coffee before Saturday."
    static let contract = "The parties agree that the closing date will move from September 18 to September 25, and that the escrow instructions will be updated to reflect the new date. Please keep the exact wording of section four, and do not change the meaning of the indemnity clause. Send the revised draft to both counsel before Thursday so there is time for review, and note that the signature pages can be exchanged electronically."
    static let booking = "Book a table for four near the window, and ask whether there is space for a stroller."
    static let directions = "Take the path along the river, turn left at the bridge, and meet outside the cafe after the walk."
    static let flights = "Search for flights to Lisbon on the twelfth, returning on the nineteenth, aisle seat if possible."

    /// Fixed IDs so tests can select an entry.
    static let latestID = UUID(uuidString: "6E0C2A40-0000-4000-8000-000000000001")!
    static let groceriesID = UUID(uuidString: "6E0C2A40-0000-4000-8000-000000000002")!
    static let contractID = UUID(uuidString: "6E0C2A40-0000-4000-8000-000000000003")!
    static let bookingID = UUID(uuidString: "6E0C2A40-0000-4000-8000-000000000004")!

    static func entries(now: Date = Date(), calendar: Calendar = .current) -> [TranscriptEntry] {
        let today = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        return [
            TranscriptEntry(id: latestID, createdAt: at(0, 10, 24), appBundleID: "com.apple.mail",
                            rawText: latestRaw, cleanText: latestText, durationMS: 12_000, audioURL: nil, insertionStatus: .inserted,
                            record: latestRecord),
            TranscriptEntry(id: groceriesID, createdAt: at(0, 9, 58), appBundleID: "com.apple.Notes",
                            rawText: groceries, cleanText: groceries, durationMS: 7_000, audioURL: nil, insertionStatus: .copiedOnly),
            TranscriptEntry(id: contractID, createdAt: at(0, 9, 31), appBundleID: "com.microsoft.Word",
                            rawText: contract, cleanText: contract, durationMS: 31_000, audioURL: nil, insertionStatus: .inserted),
            TranscriptEntry(id: bookingID, createdAt: at(0, 8, 47), appBundleID: "com.apple.iWork.Pages",
                            rawText: booking, cleanText: booking, durationMS: 6_000, audioURL: nil, insertionStatus: .failed),
            TranscriptEntry(createdAt: at(-1, 17, 40), appBundleID: "com.apple.MobileSMS",
                            rawText: directions, cleanText: directions, durationMS: 8_000, audioURL: nil, insertionStatus: .inserted),
            TranscriptEntry(createdAt: at(-1, 16, 12), appBundleID: "com.apple.Safari",
                            rawText: flights, cleanText: flights, durationMS: 9_000, audioURL: nil, insertionStatus: .inserted),
        ]
    }

    static let latestRecord = DictationRecord(
        recordingMS: 12_000, transcriptionMS: 840, cleanupMS: 20, insertionMS: 50,
        microphoneName: "MacBook Pro Microphone", modelName: "Small", insertionMethod: "typed", appName: "Mail",
        cleanupChanges: [CleanupChangeRecord(kind: "removed", before: "um", after: nil),
                         CleanupChangeRecord(kind: "added", before: nil, after: ".")]
    )

    /// Minutes per week, oldest first; the last is this week so far.
    static let weeklyMinutes = [2, 3, 2, 0, 4, 5, 3, 6, 4, 7, 5, 0, 6, 8, 7, 9, 6, 14, 9, 10, 8, 12, 11, 7, 3, 4]

    /// `countedWeeks` limits the coverage to the latest weeks, as when Steno began keeping
    /// counts partway through the calendar.
    static func usageSnapshot(weeks: [Int] = weeklyMinutes, countedWeeks: Int? = nil, now: Date = Date(),
                              calendar: Calendar = .current) -> UsageAnalyticsSnapshot {
        let apps = ["com.apple.mail", "com.apple.mail", "com.microsoft.Word", "com.apple.Notes", "com.apple.MobileSMS"]
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return .empty }
        var events: [UsageEvent] = []
        for (index, minutes) in weeks.enumerated() where minutes > 0 {
            let weekStart = calendar.date(byAdding: .day, value: -7 * (weeks.count - 1 - index), to: thisWeek) ?? thisWeek
            let sessions = max(1, minutes / 2)
            let perSession = minutes * 60_000 / sessions
            for session in 0..<sessions {
                var day = calendar.date(byAdding: .day, value: (session * 3 + index) % 7, to: weekStart) ?? weekStart
                if day > now { day = calendar.startOfDay(for: now) }
                let created = calendar.date(byAdding: .hour, value: 9 + session % 8, to: calendar.startOfDay(for: day)) ?? day
                let words = perSession * 121 / 60_000
                events.append(UsageEvent(
                    id: UUID(), createdAt: min(created, now), appBundleID: apps[(index + session) % apps.count],
                    rawWordCount: words, finalWordCount: words, durationMS: perSession, durationQuality: .captureExact,
                    cleanupChanges: UsageCleanupBreakdown(fillerRemovals: session % 3, lexiconCorrections: session % 5 == 0 ? 1 : 0,
                                                          punctuationChanges: 1 + session % 2),
                    cleanupQuality: .exact, insertionStatus: .inserted))
            }
        }
        let start = calendar.date(byAdding: .day, value: -7 * ((countedWeeks ?? weeks.count) - 1), to: thisWeek) ?? thisWeek
        return UsageAnalyticsCalculator.snapshot(events: events, coverage: [UsageCoverageInterval(start: start, end: nil)],
                                                 now: now, calendar: calendar)
    }

    // MARK: Worst case

    /// A four-minute hands-free email with paragraphs, 560 words.
    static let longEmail = """
        Hi Dana,

        Thanks for sending the revised draft. I went through it this morning and have a few notes before we send it to the other side. First, the closing date in section four still says September 18; it should be September 25 to match what we agreed on the call. Second, the escrow instructions need to reference the new date as well, and the deposit schedule should stay exactly as it was in the original agreement. Third, the inspection paragraph reads as if the buyer can extend the period alone; please make clear that any extension needs both parties to agree in writing.

        On the indemnity clause, I would rather we left the wording alone. Their counsel asked for a cap on the seller’s exposure, and I understand why, but the cap they proposed is lower than the repair estimate we already have from the surveyor. If we accept it as written, we are effectively agreeing to cover the difference ourselves. I suggest we reply that the cap can be discussed once the final inspection report is in, and not before. I have attached the surveyor’s estimate so they can see the figures for themselves, and I am happy to walk their counsel through it on a short call if that helps.

        The title search came back clean apart from the old easement along the eastern boundary. The surveyor thinks it was never used and could be released with a short deed, but that takes time and needs the neighbour’s signature. For now, I would disclose it in the schedule of exceptions and add a sentence saying the seller will cooperate with any release the buyer wants to pursue after closing. That keeps the timetable intact without hiding anything.

        Two smaller points. The definition of business day in the first section does not match the one in the escrow letter, so one of them should change; I prefer the escrow letter’s version because it mentions public holidays in both states. And the notice addresses at the end still list the old office on Harbour Street. Please update them to the new address and add the email address for notices, since both sides have been relying on email for weeks.

        On timing, I would like the revised draft to go out by Thursday afternoon at the latest. That gives the other side the weekend to review it and still leaves us three working days before the signing appointment. If their comments come back on Monday, we can turn a final version on Tuesday and circulate signature pages on Wednesday morning. The signature pages can be exchanged electronically, and the originals can follow by courier the same day.

        Finally, could you check with accounts whether the deposit has cleared? The bank confirmed the transfer on Friday, but I have not seen the receipt in the file, and I would rather not discover a problem the day before closing. If it has not cleared by Wednesday, please call me rather than emailing, because I will be travelling and may not see messages until late in the evening.

        Once those are in, I am happy for it to go out. Thanks again for turning this around so quickly, and let me know if anything is unclear or if you would like to talk any of it through before Thursday.

        Best wishes,
        Sam Lee
        """
    static let dictatedURL = "Open https://example.com/workspaces/acme/projects/q3-launch/docs/9f8e7d6c5b4a?tab=comments&filter=unresolved and leave a comment on the second paragraph"
    /// One 300-character token with nowhere to break: a pasted link dictated on its own.
    static let unbreakableToken = "https://example.com/workspaces/northwind-industries-holdings/projects/q3-launch-retrospective/documents/9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f/revisions/a1b2c3d4e5f60718293a4b5c6d7e8f90?tab=comments&filter=unresolved&sort=newest&highlight=section-four-closing-date&ref=email-digest-2026-10&view=weekly1"
    static let hebrew = "אני אתקשר אליך אחרי הפגישה כדי לעבור על החוזה לפני יום חמישי"
    static let zwjEmoji = "👩🏽‍💻👨‍👩‍👧‍👦 Ship it 🏳️‍🌈🧑🏿‍🚀"
    /// Leading and trailing whitespace and blank lines, as a dictation can arrive.
    static let padded = "\n\n   Call me back when you land.   \n\n"
    static let worstLatestID = UUID(uuidString: "6E0C2A40-0000-4000-8000-0000000000F1")!

    /// Realistic content extremes, spread across the first rows: long, unbreakable, one word,
    /// no speech, CJK, right-to-left, emoji with joiners, padded whitespace, several exceptions
    /// at once, unknown and uninstalled apps, a line break in a short dictation, both sides of
    /// the last new year, and a three-year-old entry.
    static func worstCaseEntries(now: Date = Date(), calendar: Calendar = .current) -> [TranscriptEntry] {
        let today = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        let copied = DictationRecord(copyReason: "secureField", recordingMS: 4_000, transcriptionMS: 300, cleanupMS: 10, insertionMS: 20,
                                     microphoneName: "Shure MV7+ Podcast Microphone (USB Audio Device)", modelName: "Large v3 Turbo",
                                     insertionMethod: "copied", appName: "Northwind-Industries-Holdings-Desktop-Client",
                                     cleanupChanges: [])
        return [
            TranscriptEntry(id: worstLatestID, createdAt: at(0, 11, 2), appBundleID: "com.microsoft.Word",
                            rawText: longEmail, cleanText: longEmail, durationMS: 241_000, audioURL: nil, insertionStatus: .inserted,
                            record: DictationRecord(recordingMS: 241_000, transcriptionMS: 6_420, cleanupMS: 180, insertionMS: 1_240,
                                                    microphoneName: "Shure MV7+ Podcast Microphone (USB Audio Device)",
                                                    modelName: "Large v3 Turbo", insertionMethod: "typed", appName: "Microsoft Word",
                                                    cleanupChanges: [])),
            TranscriptEntry(createdAt: at(0, 10, 51), appBundleID: "com.example.Northwind-Industries-Holdings-Desktop-Client",
                            rawText: dictatedURL, cleanText: dictatedURL, durationMS: 9_000, audioURL: nil, insertionStatus: .copiedOnly,
                            record: copied, fixes: [WordFix(original: "comment", replacement: "Comment", occurrence: 0, appliesToFuture: false, date: now)]),
            TranscriptEntry(createdAt: at(0, 10, 40), appBundleID: "com.apple.MobileSMS",
                            rawText: "Yes.", cleanText: "Yes.", durationMS: 900, audioURL: nil, insertionStatus: .inserted),
            TranscriptEntry(createdAt: at(0, 10, 38), appBundleID: "com.example.unknown-capture-tool",
                            rawText: unbreakableToken, cleanText: unbreakableToken, durationMS: 11_000, audioURL: nil,
                            insertionStatus: .inserted),
            TranscriptEntry(createdAt: at(0, 10, 36), appBundleID: "com.apple.mail",
                            rawText: hebrew, cleanText: hebrew, durationMS: 5_000, audioURL: nil, insertionStatus: .inserted),
            TranscriptEntry(createdAt: at(0, 10, 35), appBundleID: "com.apple.MobileSMS",
                            rawText: zwjEmoji, cleanText: zwjEmoji, durationMS: 2_000, audioURL: nil, insertionStatus: .inserted),
            TranscriptEntry(createdAt: at(0, 10, 34), appBundleID: "com.apple.Notes",
                            rawText: padded, cleanText: padded, durationMS: 2_500, audioURL: nil, insertionStatus: .inserted),
            TranscriptEntry(createdAt: at(0, 10, 33), appBundleID: "",
                            rawText: "", cleanText: "", durationMS: 2_000, audioURL: nil, insertionStatus: .noSpeech),
            TranscriptEntry(createdAt: at(0, 9, 12), appBundleID: "com.tinyspeck.slackmacgap",
                            rawText: "明天上午十点开会，请把议程和预算表发给大家，我们需要在周五之前确认所有细节。",
                            cleanText: "明天上午十点开会，请把议程和预算表发给大家，我们需要在周五之前确认所有细节。",
                            durationMS: 6_000, audioURL: nil, insertionStatus: .inserted),
            TranscriptEntry(createdAt: at(0, 8, 5), appBundleID: "com.apple.mail",
                            rawText: "سأتصل بك بعد الاجتماع لنراجع العقد معًا قبل يوم الخميس",
                            cleanText: "سأتصل بك بعد الاجتماع لنراجع العقد معًا قبل يوم الخميس",
                            durationMS: 5_000, audioURL: nil, insertionStatus: .failed),
            TranscriptEntry(createdAt: at(0, 0, 3), appBundleID: "com.apple.MobileSMS",
                            rawText: "Sounds great 👍🏽 see you at 7\nbring the 🍕", cleanText: "Sounds great 👍🏽 see you at 7\nbring the 🍕",
                            durationMS: 3_000, audioURL: nil, insertionStatus: .copiedOnly, pasteAttempted: true),
            TranscriptEntry(createdAt: yearBoundary(now: now, calendar: calendar, minutes: 1), appBundleID: "com.apple.mail",
                            rawText: "Happy new year, everyone.", cleanText: "Happy new year, everyone.",
                            durationMS: 2_000, audioURL: nil, insertionStatus: .inserted),
            TranscriptEntry(createdAt: yearBoundary(now: now, calendar: calendar, minutes: -2), appBundleID: "com.apple.mail",
                            rawText: "Last one of the year: send the invoice.", cleanText: "Last one of the year: send the invoice.",
                            durationMS: 3_000, audioURL: nil, insertionStatus: .inserted),
            TranscriptEntry(createdAt: calendar.date(byAdding: .year, value: -3, to: at(0, 14, 0)) ?? today,
                            appBundleID: "com.apple.Notes",
                            rawText: "Use **bold** and <b>tags</b> &amp; keep them literal.", cleanText: "Use **bold** and <b>tags</b> &amp; keep them literal.",
                            durationMS: 4_000, audioURL: nil, insertionStatus: .inserted),
        ]
    }

    /// One dictation, so every count is exactly 1.
    static func oneEntry(now: Date = Date()) -> [TranscriptEntry] { Array(entries(now: now).prefix(1)) }

    /// The History limit: 1,000 dictations over the last few weeks.
    static func thousandEntries(now: Date = Date(), calendar: Calendar = .current) -> [TranscriptEntry] {
        let base = entries(now: now)
        return (0..<1_000).map { index in
            var entry = base[index % base.count]
            entry.id = UUID()
            entry.createdAt = calendar.date(byAdding: .minute, value: -37 * index, to: now) ?? now
            return entry
        }
    }

    /// Minutes either side of the most recent New Year's midnight: `-2` is December 31, 23:58.
    static func yearBoundary(now: Date = Date(), calendar: Calendar = .current, minutes: Int) -> Date {
        let year = calendar.component(.year, from: now)
        let midnight = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        return calendar.date(byAdding: .minute, value: minutes, to: midnight) ?? midnight
    }

    /// The History limit, every one dictated today and each as long as `text`: the largest
    /// counts the Today header can show.
    static func heavyDay(count: Int = 1_000, text: String = longEmail, now: Date = Date(),
                         calendar: Calendar = .current) -> [TranscriptEntry] {
        let today = calendar.startOfDay(for: now)
        let span = max(1, now.timeIntervalSince(today) - 60)
        return (0..<count).map { index in
            TranscriptEntry(createdAt: now.addingTimeInterval(-span * Double(index) / Double(count)), appBundleID: "com.apple.mail",
                            rawText: text, cleanText: text, durationMS: 240_000, audioURL: nil, insertionStatus: .inserted)
        }
    }

    /// Usage from explicit days: `dailyWords[n]` words dictated `n` days before today (0 is
    /// today). Counting began `countedFromDaysAgo` days ago, or with the whole calendar.
    static func usageSnapshot(dailyWords: [Int: Int], countedFromDaysAgo: Int? = nil, now: Date = Date(),
                              calendar: Calendar = .current) -> UsageAnalyticsSnapshot {
        let today = calendar.startOfDay(for: now)
        let apps = ["com.apple.mail", "com.example.Northwind-Industries-Holdings-Desktop-Client", "com.microsoft.Word",
                    "com.example.unknown-capture-tool", "com.apple.Notes"]
        let events: [UsageEvent] = dailyWords.sorted { $0.key > $1.key }.enumerated().compactMap { index, day in
            guard day.value > 0, let start = calendar.date(byAdding: .day, value: -day.key, to: today) else { return nil }
            let created = min(calendar.date(byAdding: .hour, value: 10, to: start) ?? start, now)
            let durationMS = Int(min(Double(day.value) * 60_000 / 121, Double(Int.max / 2)))
            return UsageEvent(
                id: UUID(), createdAt: created, appBundleID: apps[index % apps.count],
                rawWordCount: day.value, finalWordCount: day.value, durationMS: durationMS, durationQuality: .captureExact,
                cleanupChanges: UsageCleanupBreakdown(fillerRemovals: 1, punctuationChanges: 1),
                cleanupQuality: .exact, insertionStatus: .inserted)
        }
        let start = calendar.date(byAdding: .day, value: -(countedFromDaysAgo ?? 7 * 26), to: today) ?? today
        return UsageAnalyticsCalculator.snapshot(events: events, coverage: [UsageCoverageInterval(start: start, end: nil)],
                                                 now: now, calendar: calendar)
    }

    /// Fills an isolated preview controller with the sample History, records and usage.
    static func install(on controller: DictationController, now: Date = Date(), weeks: [Int] = weeklyMinutes) {
        precondition(controller.isIsolatedPreview, "Sample data only goes into isolated previews.")
        controller.recentEntries = entries(now: now)
        controller.lastTranscript = latestText
        controller.usageAnalyticsSnapshot = usageSnapshot(weeks: weeks, now: now)
    }
}
#endif
