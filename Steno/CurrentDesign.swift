import SwiftUI

struct CurrentDictationLayout<Header: View, Controls: View, Shortcuts: View, Transcript: View>: View {
    @Environment(\.sizeCategory) private var sizeCategory

    let header: Header
    let controls: Controls
    let shortcuts: Shortcuts
    let transcript: Transcript
    let theme: StenoTheme
    let availableSize: CGSize

    private var stacksHero: Bool {
        availableSize.width < 700 || sizeCategory.isAccessibilityCategory
    }

    private var heroLayout: AnyLayout {
        stacksHero
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 24))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            heroLayout {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                controls
                    .frame(width: 180, alignment: stacksHero ? .leading : .center)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CurrentSoftWell(theme: theme, accented: true, cornerRadius: 28))

            shortcuts
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

            Rectangle()
                .fill(theme.lineStrong)
                .frame(height: 1)
                .accessibilityHidden(true)

            transcript
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .frame(maxWidth: 1_120, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct CurrentHistoryLayout<ListContent: View, DetailContent: View>: View {
    let list: ListContent
    let detail: DetailContent
    let theme: StenoTheme
    let availableSize: CGSize

    private var listWidth: CGFloat {
        min(336, max(260, (availableSize.width - 48) * 0.34))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            list
                .frame(width: listWidth)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(CurrentSoftWell(theme: theme, accented: false, cornerRadius: 22))

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(CurrentSoftWell(theme: theme, accented: false, cornerRadius: 28))
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CurrentInsightsLayout<Metrics: View, CalendarContent: View, Details: View>: View {
    let metrics: Metrics
    let calendar: CalendarContent
    let details: Details
    let theme: StenoTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            metrics
                .frame(maxWidth: .infinity, alignment: .leading)

            CurrentInsightsColumns {
                calendar
                details
            }
        }
        .frame(maxWidth: 1_200, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct CurrentSettingsLayout<Content: View, Footer: View>: View {
    let content: Content
    let footer: Footer
    let theme: StenoTheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(32)
                    .background {
                        CurrentSoftWell(theme: theme, accented: false, cornerRadius: 26)
                            .padding(16)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            footer
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.ink0)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.lineStrong)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CurrentOnboardingLayout<ProgressContent: View, Content: View, Navigation: View>: View {
    let progress: ProgressContent
    let content: Content
    let navigation: Navigation
    let theme: StenoTheme

    var body: some View {
        VStack(spacing: 0) {
            progress
                .frame(maxWidth: 800)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)

            ScrollView {
                content
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(28)
                    .background(CurrentSoftWell(theme: theme, accented: true, cornerRadius: 28))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .top)
            }

            navigation
                .frame(maxWidth: 800)
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(theme.ink0)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.lineStrong)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Keeps calendar selection and disclosure state intact as the detail rail reflows.
private struct CurrentInsightsColumns: Layout {
    private let spacing: CGFloat = 24
    private let railWidth: CGFloat = 340
    private let minimumSplitWidth: CGFloat = 980

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = max(0, proposal.width ?? minimumSplitWidth)
        let split = width >= minimumSplitWidth
        let firstWidth = split ? width - railWidth - spacing : width
        let secondWidth = split ? railWidth : width
        let first = subviews[0].sizeThatFits(ProposedViewSize(width: firstWidth, height: nil))
        let second = subviews[1].sizeThatFits(ProposedViewSize(width: secondWidth, height: nil))
        return CGSize(
            width: width,
            height: split ? max(first.height, second.height) : first.height + spacing + second.height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let split = bounds.width >= minimumSplitWidth
        let firstWidth = split ? bounds.width - railWidth - spacing : bounds.width
        let secondWidth = split ? railWidth : bounds.width
        let firstProposal = ProposedViewSize(width: firstWidth, height: nil)
        let firstSize = subviews[0].sizeThatFits(firstProposal)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: firstProposal)
        subviews[1].place(
            at: CGPoint(
                x: split ? bounds.minX + firstWidth + spacing : bounds.minX,
                y: split ? bounds.minY : bounds.minY + firstSize.height + spacing
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: secondWidth, height: nil)
        )
    }
}

private struct CurrentSoftWell: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let theme: StenoTheme
    let accented: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(theme.ink1)
            .overlay {
                if accented {
                    shape.fill(theme.accent.opacity(theme.isLight ? 0.08 : 0.10))
                }
            }
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? theme.textDim : theme.line,
                    lineWidth: contrast == .increased ? 2 : 1
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
