import SwiftUI
import StenoKit

struct InsertionSettingsSection: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        settingsCard("Text Output (Insertion)") {
            Text("Choose how Steno inserts text. Drag to set priority. Backup paste via clipboard is always kept.")
                .font(StenoDesign.caption())
                .foregroundStyle(StenoDesign.textSecondary)

            List {
                ForEach(controller.preferences.insertion.orderedMethods, id: \.rawValue) { method in
                    HStack {
                        Image(systemName: icon(for: method))
                            .foregroundStyle(StenoDesign.accent)
                        Text(label(for: method))
                        Spacer()
                    }
                    .accessibilityHint("Drag to reorder")
                }
                .onMove(perform: moveInsertionMethod)
            }
            .frame(height: StenoDesign.insertionListHeight)
            .clipShape(RoundedRectangle(cornerRadius: StenoDesign.radiusSmall))

            HStack {
                Toggle(
                    "Type directly",
                    isOn: Binding(
                        get: { controller.preferences.insertion.orderedMethods.contains(.direct) },
                        set: { setInsertionMethod(.direct, enabled: $0) }
                    )
                )
                Toggle(
                    "Accessibility insert",
                    isOn: Binding(
                        get: { controller.preferences.insertion.orderedMethods.contains(.accessibility) },
                        set: { setInsertionMethod(.accessibility, enabled: $0) }
                    )
                )
                Toggle(
                    "Backup paste via clipboard",
                    isOn: Binding(
                        get: { controller.preferences.insertion.orderedMethods.contains(.clipboardPaste) },
                        set: { setInsertionMethod(.clipboardPaste, enabled: $0) }
                    )
                )
            }
        }
    }

    private func moveInsertionMethod(from source: IndexSet, to destination: Int) {
        controller.preferences.insertion.orderedMethods.move(fromOffsets: source, toOffset: destination)
        if !controller.preferences.insertion.orderedMethods.contains(.clipboardPaste) {
            controller.preferences.insertion.orderedMethods.append(.clipboardPaste)
        }
    }

    private func setInsertionMethod(_ method: InsertionMethod, enabled: Bool) {
        if enabled {
            if !controller.preferences.insertion.orderedMethods.contains(method) {
                controller.preferences.insertion.orderedMethods.append(method)
            }
        } else {
            if method == .clipboardPaste { return }
            controller.preferences.insertion.orderedMethods.removeAll { $0 == method }
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
