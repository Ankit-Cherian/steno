import AppKit
import StenoKit
import SwiftUI

/// Where each target of the panel sits, reported in the panel's own coordinate space so the
/// panel can place the pointer and VoiceOver on the right row.
private struct GroveMenuFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    func groveMenuTarget(_ id: String, in space: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: GroveMenuFramesKey.self, value: [id: proxy.frame(in: .named(space))])
        })
    }
}

/// The Grove menu bar panel, "Quiet": one forest panel that looks the same in light and dark,
/// cream text, no ruled lines. Groups separate by a 6 pt gap. The pointer and keyboard are
/// handled by the panel, so this view only draws `GroveMenuState`.
struct GroveMenuView: View {
    static let width: CGFloat = 290
    static let cornerRadius: CGFloat = 14
    private static let space = "grove-menu"

    @ObservedObject var state: GroveMenuState
    @Environment(\.groveTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
            if let attention = state.layout.attention { attentionStrip(attention) }
            latestCard
            VStack(spacing: 6) {
                ForEach(Array(state.layout.groups.enumerated()), id: \.offset) { _, group in
                    VStack(spacing: 0) {
                        ForEach(group) { row in rowView(row) }
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
        .frame(width: Self.width, alignment: .leading)
        .foregroundStyle(theme.creamColor)
        .background(shape.fill(theme.panelGradient))
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
        .clipShape(shape)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(GroveMenuFramesKey.self) { state.frames = $0 }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            statusMark
            VStack(alignment: .leading, spacing: 1) {
                statusTitle
                if let subtitle = state.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.subtextColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let primary = state.layout.primary { primaryButton(primary) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// A mint dot at rest, an amber one when Steno cannot dictate, bars that follow the voice
    /// while listening, three dots while transcribing.
    @ViewBuilder
    private var statusMark: some View {
        switch state.snapshot.iconState {
        case .recording:
            GroveLevelBars(source: state.haloSource, color: theme.mint.nsColor, count: 5)
                .frame(width: 22.5, height: 18)
                .frame(width: 24)
        case .transcribing:
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle().fill(theme.mintColor.opacity([1, 0.6, 0.3][index])).frame(width: 5, height: 5)
                }
            }
            .frame(width: 24, alignment: .leading)
        case .idle:
            Circle().fill(theme.mintColor).frame(width: 7, height: 7).padding(.horizontal, 2)
        case .attention:
            Circle().fill(theme.warningColor).frame(width: 7, height: 7).padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var statusTitle: some View {
        if state.snapshot.iconState == .recording, let start = state.snapshot.recordingStartedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                title(state.title + "  " + QuillStatusPillState.elapsed(Int(context.date.timeIntervalSince(start))))
            }
        } else {
            title(state.title)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .monospacedDigit()
    }

    private func primaryButton(_ row: GroveMenuRow) -> some View {
        let isStop = row.action == .stop
        let focused = state.highlightedID == row.id
        let shape = Capsule()
        return HStack(spacing: 5) {
            Image(systemName: isStop ? "stop.fill" : "mic.fill")
                .font(.system(size: 10, weight: .bold))
            Text(row.title).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(theme.onPanelCreamColor)
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(shape.fill(theme.creamColor.opacity(row.isEnabled ? 1 : 0.4)))
        .overlay(shape.strokeBorder(theme.mintColor, lineWidth: focused ? 2 : 0))
        .fixedSize()
        .groveMenuTarget(row.id, in: Self.space)
    }

    // MARK: Attention

    private func attentionStrip(_ row: GroveMenuRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "mic.slash")
                .font(.system(size: 12))
                .foregroundStyle(theme.warningColor)
            Text("Microphone access is off")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            softPill(row.title, focused: state.highlightedID == row.id)
                .groveMenuTarget(row.id, in: Self.space)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.warningColor.opacity(0.14)))
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private func softPill(_ text: String, focused: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .overlay(Capsule().strokeBorder(theme.mintColor, lineWidth: focused ? 2 : 0))
            .fixedSize()
    }

    // MARK: Latest dictation

    /// The words on the latest dictation's card. One with no words says why, as History does,
    /// rather than leaving the card blank.
    static func cardText(for entry: TranscriptEntry) -> (text: String, hasWords: Bool) {
        let preview = GrovePreviewText.make(entry.cleanText.isEmpty ? entry.rawText : entry.cleanText)
        guard preview.isEmpty else { return (preview, true) }
        return (entry.insertionStatus == .noSpeech ? "No speech detected" : "No text", false)
    }

    private var latestCard: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            if let entry = state.layout.latest {
                HStack(spacing: 6) {
                    GroveAppIcon(bundleID: entry.appBundleID, size: 14)
                    if !entry.appBundleID.isEmpty {
                        Text(AppNames.name(for: entry))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.subtextColor)
                            .lineLimit(1)
                    }
                    Text(ClockTime.string(entry.createdAt))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(theme.subtextColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    copyGlyph
                }
                let card = Self.cardText(for: entry)
                Text(card.text)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(card.hasWords ? theme.creamColor : theme.subtextColor)
                    .groveTextDirection(rightToLeft: GrovePreviewText.isRightToLeft(card.text))
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Text(state.snapshot.hasUnsavedLast
                         ? "Your last dictation wasn’t saved to History."
                         : "No dictations yet.")
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .foregroundStyle(state.snapshot.hasUnsavedLast ? theme.creamColor : theme.subtextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    copyGlyph
                }
            }
        }
        .padding(10)
        .background(shape.fill(Color.white.opacity(0.07)))
        .overlay(shape.strokeBorder(Color.white.opacity(theme.increaseContrast ? 0.4 : 0), lineWidth: 1))
        .padding(.horizontal, 6)
    }

    /// Copy Last Dictation: the glyph on the card.
    @ViewBuilder
    private var copyGlyph: some View {
        if let row = state.layout.latestCopy {
            let highlighted = state.highlightedID == row.id
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.mintColor)
                .padding(4)
                .background(shape.fill(Color.white.opacity(highlighted ? Self.highlightOpacity(increaseContrast: theme.increaseContrast) : 0)))
                .overlay(shape.strokeBorder(Color.white.opacity(highlighted && theme.increaseContrast ? 0.55 : 0), lineWidth: 1))
                .opacity(row.isEnabled ? 1 : 0.45)
                .groveMenuTarget(row.id, in: Self.space)
                .padding(-4)
        }
    }

    /// The highlighted row's wash: white at 15% (20% with Increase Contrast, which adds an edge).
    /// At 10% the keyboard's place in the panel was hard to find against the forest.
    static func highlightOpacity(increaseContrast: Bool) -> Double { increaseContrast ? 0.2 : 0.15 }

    // MARK: Rows

    private func rowView(_ row: GroveMenuRow) -> some View {
        let highlighted = state.highlightedID == row.id
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return HStack(spacing: 8) {
            if let entry = row.entry {
                Text(ClockTime.string(entry.createdAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.subtextColor)
            }
            Text(row.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing(row)
        }
        .padding(.leading, row.isNested ? 20 : 8)
        .padding(.trailing, 8)
        .frame(height: 24)
        .opacity(row.isEnabled ? 1 : 0.45)
        .background(shape.fill(Color.white.opacity(highlighted ? Self.highlightOpacity(increaseContrast: theme.increaseContrast) : 0)))
        .overlay(shape.strokeBorder(Color.white.opacity(highlighted && theme.increaseContrast ? 0.55 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .groveMenuTarget(row.id, in: Self.space)
    }

    @ViewBuilder
    private func trailing(_ row: GroveMenuRow) -> some View {
        if let detail = row.detail {
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.subtextColor)
                .lineLimit(1)
        }
        if case .disclosure = row.behaviour {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.subtextColor)
                .rotationEffect(.degrees(row.isChecked ? 90 : 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: row.isChecked)
        } else if row.isChecked {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.mintColor)
        } else if let shortcut = row.shortcut {
            Text(shortcut)
                .font(.system(size: 12))
                .foregroundStyle(theme.subtextColor)
        }
    }
}
