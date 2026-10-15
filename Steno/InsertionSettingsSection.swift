import SwiftUI
import StenoKit
import UniformTypeIdentifiers

struct InsertionSettingsSection: View {
    @Binding var preferences: AppPreferences
    @State private var dragged: InsertionMethod?
    @Environment(\.quillTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageHeader(
                section: .output,
                intro: "Steno tries these in order and stops at the first that works. Drag to reorder, or use the arrows."
            )
            SettingsCard {
                let methods = Self.displayOrder(preferences.insertion.orderedMethods)
                ForEach(Array(methods.enumerated()), id: \.element.rawValue) { index, method in
                    row(method, index: index, count: methods.count)
                }
            }
            HStack {
                SettingsFootnote(text: "Terminals and remote desktops start with paste. In a password field, or if you switched apps while Steno was transcribing, the text is copied instead and the overlay says so.")
            }
        }
    }

    /// Enabled methods in their saved order, then the ones that are off.
    static func displayOrder(_ ordered: [InsertionMethod]) -> [InsertionMethod] {
        let all: [InsertionMethod] = [.direct, .accessibility, .clipboardPaste]
        return ordered.filter(all.contains) + all.filter { !ordered.contains($0) }
    }

    private func row(_ method: InsertionMethod, index: Int, count: Int) -> some View {
        let enabledCount = preferences.insertion.orderedMethods.count
        let isOn = preferences.insertion.orderedMethods.contains(method)
        return HStack(spacing: 12) {
            Text("\(index + 1)")
                .settingsFont(.mono)
                .foregroundStyle(theme.ink3)
                .frame(width: 20, alignment: .leading)
                .accessibilityHidden(true)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(theme.ink3)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(for: method)).settingsFont(.label).foregroundStyle(theme.ink)
                Text(Self.detail(for: method)).settingsFont(.caption).foregroundStyle(theme.ink3)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { move(method, by: -1) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 26)
                }
                .disabled(!isOn || index == 0)
                .accessibilityLabel("Move \(Self.title(for: method)) up")
                Button { move(method, by: 1) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 28, height: 26)
                }
                .disabled(!isOn || index >= enabledCount - 1)
                .accessibilityLabel("Move \(Self.title(for: method)) down")
            }
            .settingsButton(.quiet)
            if method == .clipboardPaste {
                Text("Always on")
                    .settingsFont(.caption)
                    .foregroundStyle(theme.ink3)
                    .frame(minWidth: 40, alignment: .trailing)
            } else {
                SettingsSwitch(label: Self.title(for: method), isOn: enabledBinding(method))
            }
        }
        .settingsRowInset(vertical: 11)
        .contentShape(Rectangle())
        .onDrag {
            dragged = method
            return NSItemProvider(object: method.rawValue as NSString)
        }
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            guard let dragged, dragged != method else { return false }
            place(dragged, at: method)
            self.dragged = nil
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(index + 1). \(Self.title(for: method))")
    }

    private func enabledBinding(_ method: InsertionMethod) -> Binding<Bool> {
        Binding(
            get: { preferences.insertion.orderedMethods.contains(method) },
            set: { enabled in
                var order = Self.displayOrder(preferences.insertion.orderedMethods)
                var enabledSet = Set(preferences.insertion.orderedMethods)
                if enabled { enabledSet.insert(method) } else { enabledSet.remove(method) }
                enabledSet.insert(.clipboardPaste)
                order = order.filter(enabledSet.contains)
                preferences.insertion.orderedMethods = order
            }
        )
    }

    private func move(_ method: InsertionMethod, by offset: Int) {
        var order = Self.displayOrder(preferences.insertion.orderedMethods)
        guard let index = order.firstIndex(of: method) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        commit(order)
    }

    private func place(_ method: InsertionMethod, at target: InsertionMethod) {
        var order = Self.displayOrder(preferences.insertion.orderedMethods)
        guard let from = order.firstIndex(of: method), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(method, at: to)
        commit(order)
    }

    /// Keeps the new order for the methods that are on.
    private func commit(_ order: [InsertionMethod]) {
        let enabled = Set(preferences.insertion.orderedMethods)
        preferences.insertion.orderedMethods = order.filter(enabled.contains)
    }

    static func title(for method: InsertionMethod) -> String {
        switch method {
        case .direct: "Type the text"
        case .accessibility: "Insert with Accessibility"
        case .clipboardPaste: "Paste from the clipboard"
        case .none: "None"
        }
    }

    static func detail(for method: InsertionMethod) -> String {
        switch method {
        case .direct: "Types it as if from the keyboard."
        case .accessibility: "Places the text straight into the field, in apps that allow it."
        case .clipboardPaste: "Always available as the last resort."
        case .none: ""
        }
    }
}
