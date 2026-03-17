import SwiftUI
import StenoKit

struct InsertionSettingsSection: View {
    @Binding var preferences: AppPreferences

    var body: some View {
        settingsCard("Text Output (Insertion)") {
            Text("Set priority order. Backup paste via clipboard is always kept.")
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)

            VStack(spacing: StenoDesign.sm) {
                ForEach(Array(preferences.insertion.orderedMethods.enumerated()), id: \.element.rawValue) { index, method in
                    HStack(spacing: StenoDesign.sm) {
                        Image(systemName: icon(for: method))
                            .foregroundStyle(StenoDesign.accent)
                        Text(label(for: method))
                            .font(StenoDesign.callout())
                            .lineLimit(1)
                        Spacer()
                        Button {
                            moveUp(index)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(StenoDesign.caption())
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)
                        .foregroundStyle(index == 0 ? StenoDesign.textSecondary.opacity(StenoDesign.opacityDisabled) : StenoDesign.textSecondary)
                        .accessibilityLabel("Move \(label(for: method)) up")

                        Button {
                            moveDown(index)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(StenoDesign.caption())
                        }
                        .buttonStyle(.plain)
                        .disabled(index == preferences.insertion.orderedMethods.count - 1)
                        .foregroundStyle(index == preferences.insertion.orderedMethods.count - 1 ? StenoDesign.textSecondary.opacity(StenoDesign.opacityDisabled) : StenoDesign.textSecondary)
                        .accessibilityLabel("Move \(label(for: method)) down")
                    }
                    .padding(.vertical, StenoDesign.xs)
                    .padding(.horizontal, StenoDesign.sm)
                    .background(StenoDesign.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
                }
            }

            HStack {
                Toggle(
                    "Type directly",
                    isOn: Binding(
                        get: { preferences.insertion.orderedMethods.contains(.direct) },
                        set: { setInsertionMethod(.direct, enabled: $0) }
                    )
                )
                Toggle(
                    "Accessibility insert",
                    isOn: Binding(
                        get: { preferences.insertion.orderedMethods.contains(.accessibility) },
                        set: { setInsertionMethod(.accessibility, enabled: $0) }
                    )
                )
                Toggle(
                    "Backup paste via clipboard",
                    isOn: Binding(
                        get: { preferences.insertion.orderedMethods.contains(.clipboardPaste) },
                        set: { setInsertionMethod(.clipboardPaste, enabled: $0) }
                    )
                )
            }
        }
    }

    private func moveUp(_ index: Int) {
        guard index > 0 else { return }
        preferences.insertion.orderedMethods.swapAt(index, index - 1)
    }

    private func moveDown(_ index: Int) {
        guard index < preferences.insertion.orderedMethods.count - 1 else { return }
        preferences.insertion.orderedMethods.swapAt(index, index + 1)
    }

    private func setInsertionMethod(_ method: InsertionMethod, enabled: Bool) {
        if enabled {
            if !preferences.insertion.orderedMethods.contains(method) {
                preferences.insertion.orderedMethods.append(method)
            }
        } else {
            if method == .clipboardPaste { return }
            preferences.insertion.orderedMethods.removeAll { $0 == method }
        }
    }

    private func label(for method: InsertionMethod) -> String {
        switch method {
        case .direct: return "Type directly"
        case .accessibility: return "Accessibility insert"
        case .clipboardPaste: return "Backup paste via clipboard"
        case .none: return "None"
        }
    }

    private func icon(for method: InsertionMethod) -> String {
        switch method {
        case .direct: return "keyboard"
        case .accessibility: return "figure.wave"
        case .clipboardPaste: return "doc.on.clipboard"
        case .none: return "xmark"
        }
    }
}
