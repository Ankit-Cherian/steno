import SwiftUI

/// Editorial composition with a common writing edge and a separate capture seal.
struct ManuscriptDictationLayout<Header: View, Controls: View, Shortcuts: View, Transcript: View>: View {
    let header: Header
    let controls: Controls
    let shortcuts: Shortcuts
    let transcript: Transcript
    let theme: StenoTheme
    let availableSize: CGSize

    private var hasRoomForSeal: Bool { availableSize.width - 64 >= 600 }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if hasRoomForSeal {
                HStack(alignment: .center, spacing: 32) {
                    header
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    controls
                        .frame(width: 180, alignment: .center)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    header
                        .frame(maxWidth: .infinity, alignment: .leading)
                    controls
                        .frame(width: 180, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                ManuscriptRule(theme: theme, accentLength: 44)
                shortcuts
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            transcript
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(theme.ink2)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.lineStrong)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.line)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
        }
        .frame(maxWidth: 1040, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keeps the native index and reading scroll views independently reachable.
struct ManuscriptHistoryLayout<ListContent: View, DetailContent: View>: View {
    let list: ListContent
    let detail: DetailContent
    let theme: StenoTheme
    let availableSize: CGSize

    private var isNarrow: Bool { availableSize.width < 660 }
    private var indexWidth: CGFloat { min(308, max(252, (availableSize.width - 32) * 0.34)) }

    var body: some View {
        Group {
            if isNarrow {
                VStack(spacing: 0) {
                    list
                        .frame(height: max(190, min(280, availableSize.height * 0.44)))
                        .padding(.vertical, 16)
                    ManuscriptRule(theme: theme, accentLength: 44)
                        .padding(.horizontal, 16)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(theme.ink2)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    list
                        .padding(.vertical, 16)
                        .frame(width: indexWidth)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    Rectangle()
                        .fill(theme.lineStrong)
                        .frame(width: 1)
                        .accessibilityHidden(true)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(theme.ink2)
                }
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.lineStrong)
                .frame(height: 1)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .padding(.leading, 16)
        .padding(.trailing, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Treats the calendar as the main usage record, below a compact statistical masthead.
struct ManuscriptInsightsLayout<Metrics: View, CalendarContent: View, Details: View>: View {
    let metrics: Metrics
    let calendar: CalendarContent
    let details: Details
    let theme: StenoTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                ManuscriptRule(theme: theme, accentLength: 44)
                metrics
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            calendar
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 24) {
                Rectangle()
                    .fill(theme.lineStrong)
                    .frame(height: 1)
                    .accessibilityHidden(true)
                details
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 1040, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A readable preference column with the save actions kept outside its scroll region.
struct ManuscriptSettingsLayout<Content: View, Footer: View>: View {
    let content: Content
    let footer: Footer
    let theme: StenoTheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ManuscriptRule(theme: theme, accentLength: 44)
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 740, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
                .frame(maxWidth: 740, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.ink2)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.lineStrong)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Setup reads as a short booklet; its progress and navigation stay in place.
struct ManuscriptOnboardingLayout<ProgressContent: View, Content: View, Navigation: View>: View {
    let progress: ProgressContent
    let content: Content
    let navigation: Navigation
    let theme: StenoTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                ManuscriptRule(theme: theme, accentLength: 44)
                progress
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 740)
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)

            ScrollView {
                content
                    .frame(maxWidth: 660, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
            }
            .opacity(hasAppeared || reduceMotion ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : 7)

            navigation
                .frame(maxWidth: 740)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(theme.ink2)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.lineStrong)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
        }
        .onAppear {
            guard !hasAppeared else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                hasAppeared = true
            }
        }
    }
}

private struct ManuscriptRule: View {
    let theme: StenoTheme
    let accentLength: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(theme.accent).frame(width: accentLength)
            Rectangle().fill(theme.lineStrong)
        }
        .frame(height: 1)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
