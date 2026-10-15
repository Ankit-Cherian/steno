import StenoKit
import SwiftUI

/// Before cleanup: the recognized words, with what cleanup removed struck and what it added
/// underlined, so the difference never relies on colour alone.
struct BeforeCleanupView: View {
    let before: String
    let after: String
    @Binding var isExpanded: Bool
    @Environment(\.quillTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 11)
                    Text("Before cleanup")
                        .font(.system(size: 13, weight: isExpanded ? .semibold : .regular))
                }
                .foregroundStyle(isExpanded ? theme.ink : theme.ink2)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.groveQuiet(cornerRadius: 6))
            .accessibilityAddTraits(isExpanded ? [.isSelected] : [])
            .accessibilityHint(isExpanded ? "Hides the words before cleanup" : "Shows the words before cleanup")
            if isExpanded {
                let segments = CleanupDiff.segments(before: before, after: after)
                diffText(segments)
                    .font(.system(size: 15))
                    .lineSpacing(15 * 0.7)
                    .foregroundStyle(theme.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.legend(for: segments))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.ink3)
                    .frame(minHeight: 28)
            }
        }
    }

    /// Says what the marks mean, naming only the kinds of change this dictation has.
    nonisolated static func legend(for segments: [CleanupDiff.Segment]) -> String {
        let removed = segments.contains { $0.kind == .removed }
        let added = segments.contains { $0.kind == .added }
        switch (removed, added) {
        case (true, true): return "Cleanup removed the struck-out words and added the underlined ones."
        case (true, false): return "Cleanup removed the struck-out words."
        case (false, true): return "Cleanup added the underlined words."
        case (false, false): return "Cleanup changed nothing in this dictation."
        }
    }

    private func diffText(_ segments: [CleanupDiff.Segment]) -> Text {
        segments.reduce(Text("")) { text, segment in
            switch segment.kind {
            case .same: return text + Text(segment.text)
            case .removed: return text + Text(segment.text).strikethrough(true, color: theme.caution).foregroundColor(theme.caution)
            case .added: return text + Text(segment.text).underline(true, color: theme.accent).foregroundColor(theme.ink)
            }
        }
    }
}
