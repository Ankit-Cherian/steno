import SwiftUI
import StenoKit

@MainActor
func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 18) {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(StenoDesign.textPrimary)
            .accessibilityAddTraits(.isHeader)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardStyle(padding: 20)
}

@MainActor
func settingsCardWithSubtitle<Content: View>(
    _ title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: StenoDesign.xs) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StenoDesign.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(StenoDesign.subheadline())
                .foregroundStyle(StenoDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardStyle(padding: 20)
}

@MainActor
func entryRow(
    leading: String,
    trailing: String? = nil,
    scope: Scope? = nil,
    onRemove: @escaping () -> Void
) -> some View {
    HStack(alignment: .top, spacing: StenoDesign.sm) {
        Text(leading)
            .font(StenoDesign.callout())
            .lineLimit(3)
            .help(leading)
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
    .padding(.vertical, 10)
    .padding(.horizontal, StenoDesign.sm)
    .background(StenoDesign.surfaceSecondary)
    .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))
}

@MainActor
func scopeBadge(_ scope: Scope) -> some View {
    Text(scopeLabel(scope))
        .font(StenoDesign.label())
        .lineLimit(1)
        .truncationMode(.middle)
        .help(scopeLabel(scope))
        .padding(.horizontal, StenoDesign.sm)
        .padding(.vertical, StenoDesign.xxs)
        .background(StenoDesign.accent.opacity(StenoDesign.opacitySubtle))
        .foregroundStyle(StenoDesign.accent)
        .clipShape(Capsule())
}

func scopeLabel(_ scope: Scope) -> String {
    switch scope {
    case .global:
        return "All apps"
    case .app(let bundleID):
        return bundleID
    }
}

@MainActor
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
                    .accessibilityLabel("App bundle ID")
            }
        }
    }
}

/// A native preference control with its explanation aligned beneath the label.
@MainActor
func settingsToggle(
    _ title: String,
    description: String? = nil,
    isOn: Binding<Bool>
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Toggle(title, isOn: isOn)
            .font(.system(size: 13))
        if let description {
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(StenoDesign.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }
}

@MainActor
func settingsTextField(_ title: String, prompt: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(StenoDesign.textPrimary)
        TextField(title, text: text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .accessibilityLabel(title)
    }
}
