import Foundation
import StenoKit

/// One chip under a dictation: "Copied · App changed", "Not inserted · Saved in History".
struct GroveEntryChip: Equatable, Identifiable {
    enum Tone: Equatable { case ok, caution, quiet }

    var text: String
    var systemImage: String
    var tone: Tone
    var id: String { text }
}

/// Pure rules behind the Grove window, so the wording and the selections are testable.
enum GroveRules {
    /// "Around then" looks back this far from the selected dictation.
    static let aroundThenWindow: TimeInterval = 30 * 60
    static let aroundThenLimit = 3

    /// The dictations from the half hour before `selected`, on the same day, oldest first, at
    /// most three. When more than three qualify the three nearest to `selected` are kept, so the
    /// cards read as the lead-up to it.
    static func aroundThen(for selected: TranscriptEntry, in entries: [TranscriptEntry],
                           calendar: Calendar = .current) -> [TranscriptEntry] {
        let nearest = entries
            .filter { entry in
                let gap = selected.createdAt.timeIntervalSince(entry.createdAt)
                return entry.id != selected.id
                    && gap > 0 && gap <= aroundThenWindow
                    && calendar.isDate(entry.createdAt, inSameDayAs: selected.createdAt)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(aroundThenLimit)
        return nearest.sorted { $0.createdAt < $1.createdAt }
    }

    /// The reason a dictation was copied rather than inserted, in words, when the record kept it.
    static func copyReasonText(_ raw: String?) -> String? {
        switch raw.flatMap(InsertionCopyReason.init(rawValue:)) {
        case .secureField: "Password field"
        case .fieldChanged: "Field changed"
        case .appChanged: "App changed"
        case .appNotResponding: "App didn’t respond"
        case .accessibilityOff: "Accessibility off"
        case .noTextField: "No text field"
        case .clipboardChanged: "Clipboard changed"
        case .other, nil: nil
        }
    }

    /// The chips a dictation shows in lists. A normal insert shows none: the list stays quiet.
    static func chips(for entry: TranscriptEntry) -> [GroveEntryChip] {
        var chips: [GroveEntryChip] = []
        switch entry.insertionStatus {
        case .inserted, .noSpeech:
            break
        case .failed:
            chips.append(GroveEntryChip(text: "Not inserted · Saved in History", systemImage: "exclamationmark.triangle", tone: .caution))
        case .copiedOnly:
            if entry.wasNotPasted {
                chips.append(GroveEntryChip(text: "Not inserted · Saved in History", systemImage: "exclamationmark.triangle", tone: .caution))
            } else if entry.wasPasted {
                chips.append(GroveEntryChip(text: "Pasted", systemImage: "checkmark", tone: .ok))
            } else {
                let reason = copyReasonText(entry.record?.copyReason)
                chips.append(GroveEntryChip(text: reason.map { "Copied · \($0)" } ?? "Copied", systemImage: "doc.on.doc", tone: .quiet))
            }
        }
        if !(entry.fixes ?? []).isEmpty {
            chips.append(GroveEntryChip(text: "Fixed", systemImage: "pencil", tone: .quiet))
        }
        return chips
    }

    /// The one result word in a detail header: "Inserted", "Copied", "Not inserted", "Pasted".
    static func result(for entry: TranscriptEntry) -> GroveEntryChip {
        switch entry.insertionStatus {
        case .inserted: GroveEntryChip(text: "Inserted", systemImage: "checkmark", tone: .ok)
        case .noSpeech: GroveEntryChip(text: "No speech", systemImage: "waveform.slash", tone: .quiet)
        case .failed: GroveEntryChip(text: "Not inserted", systemImage: "exclamationmark.triangle", tone: .caution)
        case .copiedOnly:
            if entry.wasNotPasted {
                GroveEntryChip(text: "Not inserted", systemImage: "exclamationmark.triangle", tone: .caution)
            } else if entry.wasPasted {
                GroveEntryChip(text: "Pasted", systemImage: "checkmark", tone: .ok)
            } else {
                GroveEntryChip(text: "Copied", systemImage: "doc.on.doc", tone: .quiet)
            }
        }
    }

}
