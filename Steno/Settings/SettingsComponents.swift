import SwiftUI

/// The top of a Settings page: title and an optional introduction.
struct SettingsPageHeader: View {
    let section: SettingsSection
    var intro: String?
    @Environment(\.quillTheme) private var theme

    /// The pane title at 20 pt semibold with no label above it, then the rows.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.groveTitle)
                .groveFont(20, .semibold)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let intro {
                Text(intro)
                    .groveFont(13)
                    .lineSpacing(2)
                    .foregroundStyle(theme.ink2)
                    .frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            Spacer().frame(height: intro == nil ? 22 : 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A group of rows on the plain ground with no box and no separators. A title is a 12 pt
/// section label.
struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content
    @Environment(\.quillTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .groveFont(12, .semibold)
                    .foregroundStyle(theme.ink3)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 22)
                    .padding(.bottom, 2)
            }
            content
        }
    }
}

/// One setting: label and help on the left, the control on the right.
struct SettingsRow<Accessory: View, Control: View>: View {
    let label: String
    var help: String?
    /// A problem with this setting, shown under the help in caution.
    var caution: String?
    var isDimmed = false
    /// Puts the control under the label instead of at the right edge, for a control too wide to
    /// leave the label room, such as a three-way segmented control.
    var stacksControl = false
    /// Shown after the label on its line, such as a badge.
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let control: Control
    @Environment(\.quillTheme) private var theme

    init(
        label: String,
        help: String? = nil,
        caution: String? = nil,
        isDimmed: Bool = false,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder control: () -> Control
    ) {
        self.label = label
        self.help = help
        self.caution = caution
        self.isDimmed = isDimmed
        self.accessory = accessory()
        self.control = control()
    }

    var body: some View {
        // Side by side when the control leaves room for a readable label; otherwise the
        // control goes under the label, as at larger text sizes.
        Group {
            if stacksControl {
                VStack(alignment: .leading, spacing: 10) {
                    labels
                    controls
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SettingsRowLayout(spacing: 24) {
                    labels
                    controls
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The control goes under the label.
    func controlBelow() -> Self {
        var row = self
        row.stacksControl = true
        return row
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .settingsFont(.label)
                    .foregroundStyle(theme.ink)
                accessory
            }
            if let help {
                Text(help)
                    .settingsFont(.caption)
                    .lineSpacing(1.5)
                    .foregroundStyle(theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caution {
                SettingsCautionLine(text: caution)
            }
        }
        .opacity(isDimmed ? 0.5 : 1)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            control
        }
        .fixedSize()
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(
        label: String,
        help: String? = nil,
        caution: String? = nil,
        isDimmed: Bool = false,
        @ViewBuilder control: () -> Control
    ) {
        self.init(
            label: label, help: help, caution: caution, isDimmed: isDimmed,
            accessory: { EmptyView() }, control: control
        )
    }
}

/// Small explanatory text under a card.
struct SettingsFootnote: View {
    let text: String
    var systemImage: String?
    @Environment(\.quillTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
            }
            Text(text)
                .settingsFont(.caption)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.ink3)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A status word with its icon: "✓ Allowed", "⚠ Not allowed".
struct SettingsStatusLabel: View {
    enum Tone { case ok, caution, quiet }

    let text: String
    let tone: Tone
    @Environment(\.quillTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            switch tone {
            case .ok:
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
            case .caution:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .medium))
            case .quiet:
                EmptyView()
            }
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var color: Color {
        switch tone {
        case .ok: theme.ok
        case .caution: theme.caution
        case .quiet: theme.ink3
        }
    }
}

/// A caution line inside a row, such as a shortcut that couldn't be registered.
struct SettingsCautionLine: View {
    let text: String
    @Environment(\.quillTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text(text)
                .settingsFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(theme.caution)
        .padding(.top, 3)
    }
}

/// A native switch tinted with the accent.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.quillTheme) private var theme

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(theme.accent)
    }
}

/// A settings row whose control is a switch, labelled for VoiceOver with the row's label.
struct SettingsToggleRow: View {
    let label: String
    var help: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(label: label, help: help) {
            SettingsSwitch(label: label, isOn: $isOn)
        }
    }
}

/// Lays out a row's labels and control side by side, or stacked when the control would leave
/// the labels less than `minimumLabelWidth`.
struct SettingsRowLayout: Layout {
    var spacing: CGFloat = 16
    var stackedSpacing: CGFloat = 10
    var minimumLabelWidth: CGFloat = 150
    var maximumLabelWidth: CGFloat = 430

    private func isStacked(width: CGFloat, control: CGSize) -> Bool {
        width - control.width - spacing < minimumLabelWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 600
        let control = subviews[1].sizeThatFits(.unspecified)
        if isStacked(width: width, control: control) {
            let labels = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width, height: labels.height + stackedSpacing + control.height)
        }
        let labelWidth = min(maximumLabelWidth, width - control.width - spacing)
        let labels = subviews[0].sizeThatFits(ProposedViewSize(width: labelWidth, height: nil))
        return CGSize(width: width, height: max(labels.height, control.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let control = subviews[1].sizeThatFits(.unspecified)
        if isStacked(width: bounds.width, control: control) {
            let labels = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: labels.height))
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + labels.height + stackedSpacing),
                proposal: ProposedViewSize(control)
            )
            return
        }
        let labelWidth = min(maximumLabelWidth, bounds.width - control.width - spacing)
        let labels = subviews[0].sizeThatFits(ProposedViewSize(width: labelWidth, height: nil))
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY - labels.height / 2),
            proposal: ProposedViewSize(width: labelWidth, height: labels.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.maxX - control.width, y: bounds.midY - control.height / 2),
            proposal: ProposedViewSize(control)
        )
    }
}
