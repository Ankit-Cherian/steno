import SwiftUI

/// The commands on the dictation a page shows: the menu bar lists them, so they can be found and
/// VoiceOver reads them with their keys, and the page answers the same keys.
enum DictationCommand: CaseIterable {
    case search, fixWord, howItWasWritten

    var title: String {
        switch self {
        case .search: "Search History"
        case .fixWord: "Fix a Word…"
        case .howItWasWritten: "How It Was Written"
        }
    }

    /// Pressed with Command.
    var key: KeyEquivalent {
        switch self {
        case .search: "f"
        case .fixWord: "e"
        case .howItWasWritten: "i"
        }
    }
}

/// What each command does on the page shown. A command with no action is dimmed in the menu.
struct DictationCommandActions {
    var search: (() -> Void)?
    var fixWord: (() -> Void)?
    var howItWasWritten: (() -> Void)?

    func action(for command: DictationCommand) -> (() -> Void)? {
        switch command {
        case .search: search
        case .fixWord: fixWord
        case .howItWasWritten: howItWasWritten
        }
    }
}

struct DictationCommandActionsKey: FocusedValueKey {
    typealias Value = DictationCommandActions
}

extension FocusedValues {
    var dictationCommands: DictationCommandActions? {
        get { self[DictationCommandActionsKey.self] }
        set { self[DictationCommandActionsKey.self] = newValue }
    }
}

/// Search History in the Edit menu; Fix a Word and How It Was Written in a Dictation menu.
struct DictationMenuCommands: Commands {
    @FocusedValue(\.dictationCommands) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            item(.search)
        }
        CommandMenu("Dictation") {
            item(.fixWord)
            item(.howItWasWritten)
        }
    }

    private func item(_ command: DictationCommand) -> some View {
        Button(command.title) { actions?.action(for: command)?() }
            .keyboardShortcut(command.key, modifiers: .command)
            .disabled(actions?.action(for: command) == nil)
    }
}

extension View {
    /// Offers `actions` to the menu bar while this page is shown, and answers their keys here too,
    /// so they work in a window that is not a scene's, such as a test's.
    func dictationCommands(_ actions: DictationCommandActions) -> some View {
        focusedSceneValue(\.dictationCommands, actions)
            .background(alignment: .topLeading) {
                ZStack {
                    ForEach(DictationCommand.allCases, id: \.self) { command in
                        if let action = actions.action(for: command) {
                            Button(command.title, action: action)
                                .keyboardShortcut(command.key, modifiers: .command)
                                // Keys only: never a stop for Tab.
                                .focusable(false)
                        }
                    }
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
    }
}
