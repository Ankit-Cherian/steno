import AppKit
import StenoKit
import SwiftUI

/// Sizes shared by the Grove pages.
enum GroveMetrics {
    /// History's list column.
    static let historyListWidth: CGFloat = 320
    /// Content padding either side of a page.
    static let pageLeading: CGFloat = 40
    /// Today, History and Insights share one column, so their edges line up in any window.
    static let columnMaxWidth: CGFloat = 960
    static let columnMargin: CGFloat = 20
    static let columnTop: CGFloat = 12
    static let columnBottom: CGFloat = 20
    /// Where text starts inside a panel.
    static let panelInset: CGFloat = 28
    static let panelTop: CGFloat = 22
    static let panelBottom: CGFloat = 24
}

extension View {
    /// Places a section's content in the shared column on the page ground.
    func groveColumn(_ theme: GroveTheme, fillsHeight: Bool = false) -> some View {
        frame(maxWidth: GroveMetrics.columnMaxWidth, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .padding(.horizontal, GroveMetrics.columnMargin)
            .padding(.top, GroveMetrics.columnTop)
            .padding(.bottom, GroveMetrics.columnBottom)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
            .background(theme.pageGroundColor)
    }

    /// The text inset inside a panel.
    func grovePanelInset() -> some View {
        padding(.horizontal, GroveMetrics.panelInset)
            .padding(.top, GroveMetrics.panelTop)
            .padding(.bottom, GroveMetrics.panelBottom)
    }
}

// MARK: - Recovery strip

/// A problem or notice at the top of a page: a soft wash, an icon, a title, one sentence and
/// one named button. No rule under it.
struct GroveStripView: View {
    let model: RecoveryStripModel
    var perform: (RecoveryStripModel.Action) -> Void = { _ in }
    var onDismiss: (() -> Void)?
    @Environment(\.groveTheme) private var theme

    var body: some View {
        let tint = model.tone == .caution ? theme.cautionColor : theme.accentColor
        HStack(spacing: 12) {
            Image(systemName: model.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .groveFont(14, .semibold)
                    .foregroundStyle(theme.inkColor)
                if !model.body.isEmpty {
                    Text(model.body)
                        .groveFont(13)
                        .foregroundStyle(theme.ink2Color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let secondary = model.secondary {
                Button(secondary.title) { perform(secondary.action) }
                    .buttonStyle(.grove(.outline, .small))
            }
            if let primary = model.primary {
                Button(primary.title) { perform(primary.action) }
                    .buttonStyle(.grove(.outline, .small))
            }
            if model.dismissible, let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.grove(.ghost, .small))
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(model.tone == .caution ? theme.cautionWash : theme.accent.opacity(0.10).color)
        )
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Window content

/// Installs the Grove tokens for the window, turns off container focus effects, and draws the
/// confirmation note and dialogs above the content.
struct GroveWindowContent<Content: View>: View {
    let accent: StenoAccentStyle
    @ObservedObject var feedback: GroveFeedback
    @ViewBuilder let content: Content

    var body: some View {
        Inner(feedback: feedback, content: content)
            .groveTheme(accentStyle: accent)
    }

    private struct Inner: View {
        @ObservedObject var feedback: GroveFeedback
        let content: Content
        @Environment(\.groveTheme) private var theme

        var body: some View {
            content
                .foregroundStyle(theme.inkColor)
                .tint(theme.accentColor)
                .groveFocusEffectsOff()
                .groveFeedbackLayer(feedback)
                .background(theme.pageGroundColor.ignoresSafeArea())
                .background(GroveWindowBackground(color: NSColor(theme.pageGroundColor)))
                .followsSystemTextSize()
        }
    }
}

/// What the main window shows before the app has loaded: the page ground the window's pages sit
/// on, so loading changes only what is on it.
struct GroveLaunchGround: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GroveTheme.resolve(scheme: scheme, increaseContrast: contrast == .increased).pageGroundColor
            .ignoresSafeArea()
    }
}

/// Paints the window itself in the page ground, so the toolbar and the content meet without a
/// change of colour.
struct GroveWindowBackground: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.backgroundColor = color }
    }
}
