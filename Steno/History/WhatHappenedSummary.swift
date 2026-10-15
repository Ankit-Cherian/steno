import StenoKit
import SwiftUI

/// The rows of What happened, from a dictation's record. Pure, so the wording is testable.
struct WhatHappenedSummary: Equatable {
    struct Row: Equatable, Identifiable {
        var step: String
        var time: String
        var detail: String
        var id: String { step }
    }

    var rows: [Row]
    var summary: String

    static func make(entry: TranscriptEntry, record: DictationRecord, appName: String,
                     calendar: Calendar = .current) -> WhatHappenedSummary {
        var rows: [Row] = []
        let after = [record.transcriptionMS, record.cleanupMS, record.insertionMS].compactMap { $0 }.reduce(0, +)
        if let recording = record.recordingMS {
            let end = entry.createdAt.addingTimeInterval(-Double(after) / 1_000)
            let start = end.addingTimeInterval(-Double(recording) / 1_000)
            let span = "\(clock(start, calendar)) to \(clock(end, calendar))"
            let detail = [record.microphoneName, span].compactMap { $0 }.joined(separator: " · ")
            rows.append(Row(step: "Recorded", time: seconds(recording), detail: detail))
        }
        if let transcription = record.transcriptionMS {
            rows.append(Row(step: "Transcribed", time: seconds(transcription),
                            detail: record.modelName.map { "\($0) model" } ?? ""))
        }
        if let cleanup = record.cleanupMS {
            rows.append(Row(step: "Cleaned up", time: seconds(cleanup), detail: cleanupDetail(record)))
        }
        if let insertion = record.insertionMS {
            let target = record.appName ?? appName
            let (step, detail): (String, String) = switch record.outcome ?? record.insertionMethod {
            case "pasted": ("Pasted", "into \(target)")
            case "copied": ("Copied", "to the clipboard")
            case DictationRecord.notPastedOutcome: ("Not inserted", "Saved in History")
            case "failed": ("Not inserted", "")
            default: ("Inserted", "into \(target)")
            }
            rows.append(Row(step: step, time: seconds(insertion), detail: detail))
        }
        let total = record.endToEndMS ?? [record.recordingMS, record.transcriptionMS, record.cleanupMS, record.insertionMS]
            .compactMap { $0 }.reduce(0, +)
        return WhatHappenedSummary(rows: rows, summary: "\(seconds(total)) from start to text. Each step ran on this Mac.")
    }

    /// "12.0 s", "0.84 s".
    static func seconds(_ milliseconds: Int) -> String {
        let value = Double(milliseconds) / 1_000
        return value >= 10 ? String(format: "%.1f s", value) : String(format: "%.2f s", value).replacingOccurrences(of: ".00 s", with: ".0 s")
    }

    static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// What cleanup did, from the record: "2 changes: removed “um”, added a period", "no changes",
    /// or "not compared" when the texts were too long to compare.
    static func cleanupDetail(_ record: DictationRecord) -> String {
        if record.cleanupComparisonSkipped == true { return "not compared" }
        return cleanupDetail(record.cleanupChanges ?? [], total: record.cleanupChangeCount)
    }

    /// "2 changes: removed “um”, added a period". `total` is every change made when `changes`
    /// holds only the first ones.
    static func cleanupDetail(_ changes: [CleanupChangeRecord], total: Int? = nil) -> String {
        guard !changes.isEmpty else { return "no changes" }
        let all = max(changes.count, total ?? 0)
        let described = changes.prefix(3).map { change -> String in
            switch change.kind {
            case "removed": return "removed \(quoted(change.before))"
            case "added": return "added \(quoted(change.after))"
            default: return "changed \(quoted(change.before)) to \(quoted(change.after))"
            }
        }
        let count = all == 1 ? "1 change" : "\(all) changes"
        return "\(count): " + described.joined(separator: ", ") + (all > 3 ? ", …" : "")
    }

    private static func quoted(_ text: String?) -> String {
        switch text?.trimmingCharacters(in: .whitespaces) {
        case ".": return "a period"
        case ",": return "a comma"
        case "?": return "a question mark"
        case let value?: return "“\(value)”"
        case nil: return "text"
        }
    }
}
