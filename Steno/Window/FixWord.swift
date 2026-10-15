import AppKit
import StenoKit
import SwiftUI

/// A Fix a word in progress on one dictation.
struct FixWordState: Equatable {
    enum Scope: Hashable {
        case thisDictation, future

        var title: String {
            switch self {
            case .thisDictation: "Just this dictation"
            case .future: "This and future dictations"
            }
        }

        /// The scopes Fix a Word offers. A dictation copied from a password field is fixed in
        /// that dictation only: its words never become a word correction.
        static func offered(for entry: TranscriptEntry) -> [Scope] {
            entry.concealedCopy == true ? [.thisDictation] : [.thisDictation, .future]
        }
    }

    var entryID: UUID
    var range: NSRange
    var word: String
    var replacement: String
    var scope: Scope = .thisDictation

    /// Which occurrence of the word this is, counting from 0, so the same word elsewhere in the
    /// dictation is left alone.
    static func occurrence(of range: NSRange, in text: String) -> Int {
        let source = text as NSString
        guard NSMaxRange(range) <= source.length else { return 0 }
        let word = source.substring(with: range)
        var count = 0
        var search = NSRange(location: 0, length: range.location)
        while search.length > 0 {
            let found = source.range(of: word, options: [], range: search)
            guard found.location != NSNotFound else { break }
            count += 1
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: max(0, range.location - next))
        }
        return count
    }

    /// Where the word sits after `replacement` is applied, for the fixed-word underline.
    static func fixedRanges(for fixes: [WordFix], in text: String) -> [NSRange] {
        let source = text as NSString
        return fixes.compactMap { fix in
            if let location = fix.location {
                let range = NSRange(location: location, length: (fix.replacement as NSString).length)
                if NSMaxRange(range) <= source.length, source.substring(with: range) == fix.replacement { return range }
            }
            var search = NSRange(location: 0, length: source.length)
            var index = 0
            while search.length > 0 {
                let found = source.range(of: fix.replacement, options: [], range: search)
                guard found.location != NSNotFound else { return nil }
                if index == fix.occurrence { return found }
                index += 1
                search = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
            }
            return nil
        }
    }
}

/// One word of a dictation in the Fix a Word list, for someone who cannot click a word in the
/// text: VoiceOver, or the keyboard alone.
struct FixWordChoice: Hashable, Identifiable {
    let range: NSRange
    let word: String
    /// The word, and which time it appears when it appears more than once: "the (2nd)".
    let label: String
    var id: Int { range.location }

    /// Every word of `text`, in order, with ranges in `text`'s UTF-16 units.
    static func choices(in text: String) -> [FixWordChoice] {
        var found: [(NSRange, String)] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, range, _, _ in
            if let word { found.append((NSRange(range, in: text), word)) }
        }
        var totals: [String: Int] = [:]
        for (_, word) in found { totals[word, default: 0] += 1 }
        var seen: [String: Int] = [:]
        let ordinal = NumberFormatter()
        ordinal.numberStyle = .ordinal
        return found.map { range, word in
            seen[word, default: 0] += 1
            let index = seen[word] ?? 1
            let label = (totals[word] ?? 1) > 1 ? "\(word) (\(ordinal.string(from: NSNumber(value: index)) ?? "\(index)"))" : word
            return FixWordChoice(range: range, word: word, label: label)
        }
    }
}

/// After a fix: what changed and where the old text still is.
struct FixWordResult: Equatable {
    var entryID: UUID
    var original: String
    var replacement: String
    var appliedToFuture: Bool
    var appName: String

    var message: String {
        appliedToFuture
            ? "Fixed here and added to Word Corrections. \(appName) still has the old text."
            : "Fixed here. \(appName) still has the old text."
    }
}

extension FixWordState {
    /// The helper under “This and future dictations”. Each word is isolated, so a right-to-left
    /// word and its correction keep their own order on either side of the arrow.
    static func futureNote(word: String, replacement: String) -> String {
        "Also adds “\u{2068}\(word)\u{2069}” → “\u{2068}\(replacement)\u{2069}” to Word Corrections."
    }
}

extension EnvironmentValues {
    /// Render tests draw popovers inline, because a popover is its own window.
    @Entry var rendersPopoversInline = false
}

/// Steno's popovers show, resize and close without animation.
///
/// A SwiftUI popover resizes to its content during the window's layout pass, as the Fix a word
/// form does when the note under its field wraps. Animated, that resize runs a nested run loop
/// inside the layout. On macOS 26, a nested run loop entered while the update cycle commits from
/// its idle step resumes a step the idle step has cleared, and the app crashes at address 0.
enum PopoverAnimation {
    @MainActor static func turnOffForEveryPopover() {
        _ = NotificationCenter.default.addObserver(forName: NSPopover.willShowNotification, object: nil, queue: nil) { note in
            guard let popover = note.object as? NSPopover else { return }
            MainActor.assumeIsolated { popover.animates = false }
        }
    }
}

/// Anchors the Fix a word form to the word: a native popover, or inline in render tests.
struct FixWordPopover<Form: View>: ViewModifier {
    let anchor: CGRect?
    /// How far left of the anchor the inline form may reach, for render tests.
    var inlineMinimumX: CGFloat = -150
    @Binding var isPresented: Bool
    @ViewBuilder let form: () -> Form
    @Environment(\.rendersPopoversInline) private var inline
    @Environment(\.quillTheme) private var theme

    func body(content: Content) -> some View {
        if inline {
            content.overlay(alignment: .topLeading) {
                if isPresented, let anchor {
                    form()
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.paper)
                                .shadow(color: .black.opacity(theme.scheme == .dark ? 0.6 : 0.22), radius: 18, y: 10)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.controlBorder.opacity(0.6), lineWidth: 0.5))
                        )
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(theme.paper)
                                .frame(width: 12, height: 12)
                                .rotationEffect(.degrees(45))
                                .offset(y: -6)
                        }
                        .offset(x: max(inlineMinimumX, anchor.midX - 155), y: anchor.maxY + 12)
                        .fixedSize()
                }
            }
        } else {
            content.popover(
                isPresented: $isPresented,
                attachmentAnchor: .rect(.rect(anchor ?? .zero)),
                arrowEdge: .bottom,
                content: form
            )
        }
    }
}
