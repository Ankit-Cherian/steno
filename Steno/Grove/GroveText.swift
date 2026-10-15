import AppKit
import StenoKit
import SwiftUI

private struct GroveWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension EnvironmentValues {
    /// Set around flowing dictation text to end it after this many lines with an ellipsis.
    @Entry var groveFlowLineLimit: Int?
}

/// How many lines the flowing text inside takes without a line limit, so Show all is offered
/// only when the limit cuts words.
struct GroveFlowLinesKey: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value = max(value, nextValue()) }
}

/// Dictation text that flows to the width it is given, in the system font on a line 1.5 times
/// the size. TextKit sets it, so selection, search highlights, fixed words and Fix a word's
/// popover all work on it.
struct GroveFlowText: View {
    let text: String
    var size: CGFloat
    var marks = TranscriptTextMarks()
    var picksWord = false
    var onPickWord: ((NSRange) -> Void)?
    /// Whether the words came from a password field: copying a selection marks it concealed.
    var concealsCopy = false
    /// The width the text flows to, kept by the owner so a popover can anchor to a word.
    @Binding var width: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.groveFlowLineLimit) private var lineLimit

    var body: some View {
        let metrics = Self.metrics(size: size, width: width, dynamicTypeSize: dynamicTypeSize, maxLines: lineLimit)
        let shown = Self.displayText(text)
        let lines = max(1, TranscriptLineCounter.lineCount(shown, metrics: metrics))
        let allLines = lineLimit == nil
            ? lines : TranscriptLineCounter.lineCount(shown, metrics: Self.metrics(size: size, width: width, dynamicTypeSize: dynamicTypeSize))
        TranscriptTextView(text: shown, metrics: metrics, marks: marks, picksWord: picksWord, onPickWord: onPickWord,
                           storedText: text, concealsCopy: concealsCopy)
            .frame(width: metrics.measure, height: CGFloat(lines) * metrics.lineHeight, alignment: .topLeading)
            // The measure follows the room, so it must not also set the minimum width of the room.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: GroveWidthKey.self, value: proxy.size.width)
            })
            .onPreferenceChange(GroveWidthKey.self) { available in
                if available > 80, abs(available - width) > 0.5 { width = available }
            }
            .preference(key: GroveFlowLinesKey.self, value: allLines)
    }

    /// The text as drawn: blank lines and spaces around the words take no room, and the last two
    /// words are joined by a no-break space so the last line never holds a lone word. Same
    /// UTF-16 length as the stored text, so Fix a Word and search ranges stay valid.
    static func displayText(_ stored: String) -> String {
        let text = blankingEdges(stored)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 24, let space = text.range(of: " ", options: .backwards),
              !text[space.upperBound...].contains("\n") else { return text }
        return text.replacingCharacters(in: space, with: "\u{00A0}")
    }

    /// Each space or line break before the first word and after the last becomes a zero-width
    /// space. Every whitespace character is one UTF-16 unit, as is the zero-width space.
    private static func blankingEdges(_ text: String) -> String {
        let blank = CharacterSet.whitespacesAndNewlines
        let scalars = text.unicodeScalars
        guard let first = scalars.first, let last = scalars.last,
              blank.contains(first) || blank.contains(last) else { return text }
        let start = scalars.firstIndex { !blank.contains($0) } ?? scalars.endIndex
        let end = scalars.lastIndex { !blank.contains($0) }.map { scalars.index(after: $0) } ?? start
        var drawn = String.UnicodeScalarView()
        drawn.append(contentsOf: repeatElement(Unicode.Scalar(0x200B)!, count: scalars[..<start].count))
        drawn.append(contentsOf: scalars[start..<end])
        drawn.append(contentsOf: repeatElement(Unicode.Scalar(0x200B)!, count: scalars[end...].count))
        return String(drawn)
    }

    static func metrics(size: CGFloat, width: CGFloat, dynamicTypeSize: DynamicTypeSize, maxLines: Int? = nil) -> TranscriptMetrics {
        TranscriptMetrics(flowing: size, measure: width, scale: GroveScale.factor(for: dynamicTypeSize), maxLines: maxLines)
    }
}

/// Dictation text for one- and two-line previews and the live stage: every run of spaces, tabs
/// and line breaks reads as one space, so a dictation that opens with a greeting on its own line
/// still previews its words. Only the start a preview can show is read.
enum GrovePreviewText {
    static func make(_ text: String, limit: Int = 400) -> String {
        collapsed(text.prefix(limit), trimsLeading: true).trimmingCharacters(in: .whitespaces)
    }

    /// Runs of whitespace become one space; a leading one is kept unless `trimsLeading`.
    static func collapsed<S: StringProtocol>(_ text: S, trimsLeading: Bool) -> String {
        LiveWordsText.collapsed(text, trimsLeading: trimsLeading)
    }

    /// Whether the first letter of `text` is from a right-to-left script, so its lines start at
    /// the right. The island uses the same rule.
    static func isRightToLeft<S: StringProtocol>(_ text: S) -> Bool {
        LiveWordsText.isRightToLeft(text)
    }
}

extension View {
    /// Starts the lines of right-to-left text at the right, in an otherwise left-to-right layout.
    func groveTextDirection(rightToLeft: Bool) -> some View {
        multilineTextAlignment(rightToLeft ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
    }
}

/// A short sentence with an icon and actions, in a rounded wash. Used for the result of Fix a
/// word and for notes under a dictation.
struct GroveNote<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let wash: Color
    let text: String
    @ViewBuilder let actions: Actions
    @Environment(\.groveTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .groveFont(13)
                .foregroundStyle(theme.inkColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(wash))
        .accessibilityElement(children: .contain)
    }
}

/// The Fix a word form in Grove's materials: Return fixes, Esc cancels.
struct GroveFixWordForm: View {
    @Binding var state: FixWordState
    var note: String?
    /// The dictation's words, when the word is chosen here rather than clicked in the text.
    var choices: [FixWordChoice] = []
    /// A fix is on its way to History; another press would be worked out against the same text.
    var isBusy = false
    /// What the fix can apply to. A password-field dictation offers only this dictation.
    var scopes: [FixWordState.Scope] = [.thisDictation, .future]
    var onCancel: () -> Void
    var onFix: () -> Void
    @Environment(\.groveTheme) private var theme
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(choices.isEmpty ? "Fix “\(state.word)”" : "Fix a Word")
                .groveFont(14, .semibold)
                .foregroundStyle(theme.inkColor)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            if !choices.isEmpty {
                Text("Word")
                    .groveFont(12)
                    .foregroundStyle(theme.ink2Color)
                    .padding(.bottom, 5)
                Picker("Word", selection: wordChoice) {
                    ForEach(choices) { Text($0.label).tag($0.range.location) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .groveFocusEffectsOn()
                .padding(.bottom, 12)
            }
            Text("Correct spelling")
                .groveFont(12)
                .foregroundStyle(theme.ink2Color)
                .padding(.bottom, 5)
            TextField("Correct spelling", text: $state.replacement)
                .textFieldStyle(.plain)
                .groveFont(13)
                .foregroundStyle(theme.inkColor)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.wellColor))
                .modifier(KeyboardFocusRing(isFocused: fieldFocused, cornerRadius: 10))
                .focused($fieldFocused)
                .labelsHidden()
                .accessibilityLabel("Correct spelling")
                .padding(.bottom, 12)
            Picker("Apply to", selection: $state.scope) {
                ForEach(scopes, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .groveFont(13)
            .groveFocusEffectsOn()
            .padding(.bottom, 8)
            if let helper = note ?? (scopes.contains(.future)
                ? FixWordState.futureNote(word: state.word, replacement: state.replacement) : nil) {
                Text(helper)
                    .groveFont(12)
                    .foregroundStyle(note == nil ? theme.ink3Color : theme.cautionColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
                    .padding(.bottom, 12)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.grove(.ghost, .small))
                    .keyboardShortcut(.cancelAction)
                Button("Fix", action: onFix)
                    .buttonStyle(.grove(.primary, .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedReplacement.isEmpty || trimmedReplacement == state.word || isBusy)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(theme.raisedColor)
        .onAppear { fieldFocused = true }
    }

    private var trimmedReplacement: String {
        state.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The chosen word, by where it starts. Choosing another word starts its correction afresh.
    private var wordChoice: Binding<Int> {
        Binding(get: { state.range.location }, set: { location in
            guard let choice = choices.first(where: { $0.range.location == location }) else { return }
            state.range = choice.range
            state.word = choice.word
            state.replacement = choice.word
        })
    }
}
