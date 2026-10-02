import SwiftUI
import StenoKit

/// Explains, once, that a data file couldn't be read in full or a transcript
/// couldn't be saved, and offers the one action that helps.
struct StorageNoticeBanner: View {
    let notice: StorageRecoveryNotice
    let theme: StenoTheme
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.amber)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if notice.recoverableText != nil {
                    Button("Copy transcript", action: onCopy)
                        .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .soft))
                        .accessibilityIdentifier("storageNotice.copy")
                }
                if notice.fileURL != nil {
                    Button("Show in Finder", action: onReveal)
                        .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .soft))
                        .accessibilityIdentifier("storageNotice.reveal")
                }
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(StenoActionButtonStyle(theme: theme, tone: .ghost))
                    .accessibilityIdentifier("storageNotice.dismiss")
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.amberSoft)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.amber).frame(height: StenoDesign.borderThin)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage notice")
    }
}
