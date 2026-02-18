import SwiftUI
import StenoKit

@MainActor
func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: StenoDesign.md) {
        Text(title)
            .font(StenoDesign.heading3())
            .foregroundStyle(StenoDesign.textPrimary)
            .accessibilityAddTraits(.isHeader)
        content()
    }
    .cardStyle()
}

@MainActor
func settingsCardWithSubtitle<Content: View>(
    _ title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: StenoDesign.md) {
        VStack(alignment: .leading, spacing: StenoDesign.xs) {
            Text(title)
                .font(StenoDesign.heading3())
                .foregroundStyle(StenoDesign.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(StenoDesign.subheadline())
                .foregroundStyle(StenoDesign.textSecondary)
        }
        content()
    }
    .cardStyle()
}

func entryRow(
    leading: String,
    trailing: String? = nil,
    scope: Scope? = nil,
    onRemove: @escaping () -> Void
) -> some View {
    HStack(spacing: StenoDesign.sm) {
        Text(leading)
            .font(StenoDesign.callout())
            .lineLimit(1)
        Spacer()
        if let trailing = trailing {
            Text(trailing)
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)
        }
        if let scope = scope {
            scopeBadge(scope)
        }
        Button("Remove", role: .destructive, action: onRemove)
            .buttonStyle(.link)
            .accessibilityLabel("Remove entry")
            .accessibilityValue(leading)
    }
    .padding(.vertical, StenoDesign.xs)
    .padding(.horizontal, StenoDesign.sm)
    .background(StenoDesign.surfaceSecondary)
    .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
}

func scopeBadge(_ scope: Scope) -> some View {
    Text(scopeLabel(scope))
        .font(StenoDesign.label())
        .padding(.horizontal, StenoDesign.sm)
        .padding(.vertical, StenoDesign.xxs)
        .background(StenoDesign.accent.opacity(StenoDesign.opacitySubtle))
        .foregroundStyle(StenoDesign.accent)
        .clipShape(Capsule())
}

func scopeLabel(_ scope: Scope) -> String {
    switch scope {
    case .global:
        return "Global"
    case .app(let bundleID):
        return bundleID
    }
}

func describedPicker<T: Hashable & CaseIterable & RawRepresentable>(
    _ label: String,
    description: String,
    selection: Binding<T>
) -> some View where T.RawValue == String {
    VStack(alignment: .leading, spacing: StenoDesign.xxs) {
        Picker(label, selection: selection) {
            ForEach(Array(T.allCases), id: \.self) { value in
                Text(value.rawValue.capitalized).tag(value)
            }
        }
        .pickerStyle(.menu)

        Text(description)
            .font(StenoDesign.caption())
            .foregroundStyle(StenoDesign.textSecondary)
            .padding(.leading, StenoDesign.xxs)
    }
}

func enumPicker<T: Hashable & CaseIterable & RawRepresentable>(
    _ label: String,
    selection: Binding<T>
) -> some View where T.RawValue == String {
    Picker(label, selection: selection) {
        ForEach(Array(T.allCases), id: \.self) { value in
            Text(value.rawValue.capitalized).tag(value)
        }
    }
    .pickerStyle(.menu)
}

struct ScopePickerRow: View {
    @Binding var isGlobal: Bool
    @Binding var bundleID: String

    var body: some View {
        HStack {
            Toggle("All apps", isOn: $isGlobal)
                .fixedSize()
            if !isGlobal {
                TextField("Bundle ID", text: $bundleID)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
