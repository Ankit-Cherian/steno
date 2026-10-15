import SwiftUI

/// Installs the Grove tokens for the Settings window and the setup guide, and the quiet
/// Settings style that the shared components read.
struct GroveSettingsContent<Content: View>: View {
    let accent: StenoAccentStyle
    @ViewBuilder let content: Content

    var body: some View {
        Inner(content: content).groveTheme(accentStyle: accent)
    }

    private struct Inner: View {
        let content: Content
        @Environment(\.groveTheme) private var theme

        var body: some View {
            content
                .foregroundStyle(theme.inkColor)
                .tint(theme.accentColor)
                .background(theme.groundColor.ignoresSafeArea())
        }
    }
}

// MARK: - Sidebar

/// The quiet sidebar: an inset rounded panel on the well fill. Group labels are 11 pt semibold
/// in the third ink, rows are 28 pt tall at 13 pt with a secondary-ink symbol, and the selected
/// row is a neutral fill, with no weight change, accent or dot.
struct GroveSettingsSidebar: View {
    @ObservedObject var session: SettingsSession
    let changedSections: Set<SettingsSection>
    @Environment(\.groveTheme) private var theme

    static let width: CGFloat = 210

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Color.clear.frame(height: 44)
            GroveSettingsSearchField(text: $session.searchText)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if session.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(SettingsGroup.allCases) { group in
                            groupLabel(group.title)
                            ForEach(group.sections) { section in
                                item(section, rows: [])
                            }
                        }
                    } else {
                        searchResults
                    }
                }
            }
            Spacer(minLength: 8)
            // The quill in the accent beside the app's name and version.
            HStack(spacing: 6) {
                GroveQuill(colors: .flat(barbs: theme.accent.opacity(0.55).nsColor, shaft: theme.accent.nsColor))
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(SettingsSidebarVersion.line)
                    .groveFont(11)
                    .monospacedDigit()
                    .foregroundStyle(theme.ink3Color)
            }
            .padding(.leading, 16)
            .padding(.bottom, 14)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.wellColor))
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .groveFont(11, .semibold)
            .foregroundStyle(theme.ink3Color)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsCatalog.search(session.searchText)
        if results.isEmpty {
            Text("No settings match “\(session.searchText)”.")
                .groveFont(12)
                .foregroundStyle(theme.ink3Color)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            groupLabel("Results")
            ForEach(results, id: \.section) { result in
                item(result.section, rows: result.rows)
            }
        }
    }

    private func item(_ section: SettingsSection, rows: [String]) -> some View {
        let isSelected = session.selectedSection == section
        let hasChanges = changedSections.contains(section)
        return Button {
            session.selectedSection = section
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: section.groveSymbolName)
                        .groveFont(13)
                        .foregroundStyle(theme.ink2Color)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(section.groveTitle)
                        .groveFont(13)
                        .foregroundStyle(theme.inkColor)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28)
                ForEach(rows.filter { $0 != section.title }, id: \.self) { row in
                    Text(row)
                        .groveFont(12)
                        .foregroundStyle(theme.ink3Color)
                        .padding(.leading, 26)
                        .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? theme.inkColor.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.groveQuiet(cornerRadius: 7))
        .padding(.horizontal, 8)
        .accessibilityLabel(section.title)
        .accessibilityValue(hasChanges ? "Unsaved changes" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.section.\(section.rawValue)")
    }
}

/// The sidebar search field: a quiet neutral fill, no border.
private struct GroveSettingsSearchField: View {
    @Binding var text: String
    @Environment(\.groveTheme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .groveFont(12)
                .foregroundStyle(theme.ink3Color)
                .accessibilityHidden(true)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .groveFont(13)
                .accessibilityLabel("Search settings")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").groveFont(12)
                        // A 24 pt target around the 12 pt mark; the outer padding gives the room back.
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.groveQuiet(cornerRadius: 12))
                .padding(.horizontal, -6)
                .foregroundStyle(theme.ink3Color)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.inkColor.opacity(0.05)))
    }
}

// MARK: - Drafts bar

/// The pill buttons of the drafts bar: Discard is a quiet pill on the bar, Save Changes is the
/// accent and, with nothing to save, a muted pill.
struct GroveDraftBarButtonStyle: ButtonStyle {
    enum Kind { case discard, save }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.groveTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = Capsule()
            configuration.label
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(minHeight: 26)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .overlay(shape.fill(Color.black.opacity(configuration.isPressed && isEnabled ? 0.10 : 0)))
                .contentShape(shape)
        }

        private var foreground: Color {
            switch kind {
            case .discard: isEnabled ? theme.inkColor : theme.ink3Color
            case .save: isEnabled ? theme.onAccentColor : theme.ink3Color
            }
        }

        private var fill: Color {
            switch kind {
            case .discard: theme.raisedColor
            case .save: isEnabled ? theme.accentColor : theme.inkColor.opacity(0.05)
            }
        }

        private var border: Color {
            guard kind == .discard else { return .clear }
            return theme.increaseContrast ? theme.ink3Color : theme.ringColor
        }
    }
}

/// What the quiet drafts bar says on its left: a status and, for pending changes, the changed
/// settings' names.
struct GroveDraftBarStatus: View {
    let state: SettingsDraftBarState
    let changes: [SettingsField]
    @Environment(\.groveTheme) private var theme

    var body: some View {
        switch state {
        case .clean:
            Text("No unsaved changes")
                .groveFont(12)
                .foregroundStyle(theme.ink3Color)
        case .pending:
            HStack(spacing: 10) {
                Circle().fill(theme.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(Self.headline(count: changes.count, fallback: state.message))
                    .groveFont(12, .medium)
                    .foregroundStyle(theme.inkColor)
                    .lineLimit(1)
                    .fixedSize()
                if let names = Self.names(changes) {
                    Text(names)
                        .groveFont(12)
                        .foregroundStyle(theme.ink3Color)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.message)
        case .saved, .savedAfterCurrentDictation:
            Label {
                Text(state.message).groveFont(12)
            } icon: {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(theme.okColor)
        case .saveFailed, .externalConflict, .modelConflict:
            Label {
                Text(state.message)
                    .groveFont(12)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
            }
            .foregroundStyle(theme.cautionColor)
        }
    }

    /// "1 unsaved change" or "3 unsaved changes"; the bar's own words when nothing is listed.
    static func headline(count: Int, fallback: String) -> String {
        switch count {
        case 0: fallback
        case 1: "1 unsaved change"
        default: "\(count) unsaved changes"
        }
    }

    /// The changed settings' names, when there are few enough to name.
    static func names(_ changes: [SettingsField]) -> String? {
        guard (1...3).contains(changes.count) else { return nil }
        return changes.map(\.title).joined(separator: ", ")
    }
}

/// The raised rounded bar that holds the drafts status, Discard and Save Changes. Its right edge
/// lines up with the right edge of the rows' controls.
struct GroveDraftBarChrome<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.groveTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.raisedColor))
        .padding(.leading, 22)
        .padding(.trailing, 25)
        .padding(.bottom, 14)
    }
}
