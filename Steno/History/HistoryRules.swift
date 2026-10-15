import StenoKit
import SwiftUI

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case inserted = "Inserted"
    case copied = "Copied"
    case notInserted = "Not inserted"
    var id: String { rawValue }

    /// The filter's name as a menu item, in Mac title case: "Not Inserted".
    var menuTitle: String {
        self == .notInserted ? "Not Inserted" : rawValue
    }
}

/// What the History page should open with, set when another tab sends you here.
struct HistoryFocusRequest: Equatable {
    var entryID: UUID
    var showsWhatHappened: Bool
}

/// What History lists, how it highlights a search, and what deleting says.
@MainActor
enum HistoryRules {
    /// The History list: every kept entry with the chosen status whose text or app name
    /// contains `query`.
    static func entries(_ entries: [TranscriptEntry], matching query: String, filter: HistoryFilter) -> [TranscriptEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .inserted: matchesFilter = entry.insertionStatus == .inserted || entry.wasPasted
            case .copied: matchesFilter = entry.insertionStatus == .copiedOnly && !entry.wasPasted && !entry.wasNotPasted
            case .notInserted: matchesFilter = entry.insertionStatus == .failed || entry.wasNotPasted
            }
            return matchesFilter && (query.isEmpty || entry.cleanText.localizedCaseInsensitiveContains(query)
                || entry.rawText.localizedCaseInsensitiveContains(query)
                || AppNames.name(for: entry).localizedCaseInsensitiveContains(query))
        }
    }

    /// Ranges of `query` in `text`, for highlighting search matches on the page.
    static func matchRanges(of query: String, in text: String) -> [NSRange] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: source.length)
        while search.length > 0 {
            let found = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard found.location != NSNotFound, found.length > 0 else { break }
            ranges.append(found)
            search = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
        }
        return ranges
    }

    /// Deletes every saved dictation, then lets go of deleted text the app still holds: the
    /// last dictation, and a notice that offers text for copying or points at a kept History
    /// copy that is now gone.
    @MainActor
    static func deleteAllHistory(using controller: DictationController) async {
        await controller.deleteAllHistory()
        guard controller.status == "History deleted." else { return }
        controller.lastTranscript = ""
        if let notice = controller.storageNotice,
           notice.recoverableText != nil
            || notice.fileURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
            controller.dismissStorageNotice()
        }
    }

    static let deleteOneTitle = "Delete this dictation?"
    static let deleteOneMessage = "It’s removed from History on this Mac. Text already inserted into other apps stays there. This can’t be undone."
    static let deleteOneButton = "Delete"
    static let deleteAllMessage = "Every dictation is removed from History on this Mac, including the backup copies Steno keeps. Text already inserted into other apps stays there. This can’t be undone."
    static let deleteAllButton = "Delete All History"

    /// Names the listed dictations. With none listed, files may still be on disk, so the
    /// title names History instead of "0 dictations".
    static func deleteAllConfirmationTitle(listedCount: Int) -> String {
        guard listedCount > 0 else { return "Delete all History?" }
        return "Delete all \(InsightsFormatting.count(listedCount, "dictation"))?"
    }
}
