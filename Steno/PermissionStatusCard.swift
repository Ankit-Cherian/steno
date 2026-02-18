import SwiftUI

struct PermissionStatusCard: View {
    let title: String
    let description: String
    let status: PermissionDiagnostics.AccessStatus
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: StenoDesign.md) {
            Image(systemName: statusIconName)
                .font(.system(size: StenoDesign.iconLG))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: StenoDesign.xxs) {
                Text(title)
                    .font(StenoDesign.bodyEmphasis())
                    .foregroundStyle(StenoDesign.textPrimary)

                Text(description)
                    .font(StenoDesign.caption())
                    .foregroundStyle(StenoDesign.textSecondary)
            }

            Spacer()

            Text(status.rawValue)
                .font(StenoDesign.label())
                .foregroundStyle(statusColor)
                .padding(.horizontal, StenoDesign.sm)
                .padding(.vertical, StenoDesign.xxs)
                .background(statusColor.opacity(StenoDesign.opacitySubtle))
                .clipShape(Capsule())
                .accessibilityLabel("Status: \(status.rawValue)")

            actionButton
        }
        .padding(StenoDesign.md)
        .background(StenoDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: StenoDesign.radiusSmall)
                .stroke(statusBorderColor, lineWidth: StenoDesign.borderNormal)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(status.rawValue). \(description)")
    }

    private var statusIconName: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted: return StenoDesign.success
        case .denied: return StenoDesign.error
        case .unknown: return StenoDesign.warning
        }
    }

    private var statusBorderColor: Color {
        switch status {
        case .granted: return StenoDesign.successBorder
        case .denied: return StenoDesign.errorBorder
        case .unknown: return StenoDesign.border
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .granted:
            EmptyView()
        case .denied:
            Button("Open Settings") {
                onOpenSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Open \(title) settings")
        case .unknown:
            Button("Grant") {
                onRequest()
            }
            .buttonStyle(.borderedProminent)
            .tint(StenoDesign.accent)
            .controlSize(.small)
            .accessibilityLabel("Grant \(title) permission")
        }
    }
}
