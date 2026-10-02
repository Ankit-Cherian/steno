#if os(macOS)
import Carbon
import Foundation
import Testing
@testable import StenoKit

private let terminalContext = AppContext(
    bundleIdentifier: "com.apple.Terminal",
    appName: "Terminal"
)

@Test("Paste uses the key that types v with Command held, not a fixed QWERTY position")
func pasteKeyCodeFollowsLayout() {
    // US QWERTY: key code 9 is v.
    #expect(MacPasteKeyCode.resolve { $0 == 9 ? "v" : ($0 == 40 ? "k" : "x") } == 9)
    // Dvorak: key code 9 is k (Command+K clears a terminal); v is key code 47.
    #expect(MacPasteKeyCode.resolve { $0 == 9 ? "k" : ($0 == 47 ? "v" : "x") } == 47)
    // Dvorak - QWERTY Command: Command remaps key code 9 back to v.
    #expect(MacPasteKeyCode.resolve { $0 == 9 ? "V" : ($0 == 47 ? "." : "x") } == 9)
    // A layout that produces no v falls back to the historical key code.
    #expect(MacPasteKeyCode.resolve { _ in nil } == 9)
}

@Test("The current layout's paste key types v with Command held")
@MainActor
func currentLayoutPasteKeyCodeTypesV() {
    let keyCode = MacPasteKeyCode.currentLayoutKeyCode()
    let character = MacPasteKeyCode.currentLayoutCharacterWithCommand(for: keyCode)
    #expect(keyCode == 9 || character?.lowercased() == "v")
}

@Test("Terminal paste posts Command with the layout's paste key")
func terminalPastePostsResolvedKeyCode() async {
    let keys = FakeKeyPoster()
    let accessibility = FakeAccessibilityClient(focusedBundle: terminalContext.bundleIdentifier)
    let service = makeProductionInsertionService(
        clipboard: MemoryClipboardService(),
        keys: keys,
        activator: FakeApplicationActivator(
            frontmost: terminalContext.bundleIdentifier,
            running: [terminalContext.bundleIdentifier]
        ),
        accessibility: accessibility,
        pasteKeyCode: 47
    )

    _ = await service.insert(text: "ls -la", target: terminalContext)

    #expect(keys.commandShortcuts.map(\.keyCode) == [47])
    #expect(keys.typedText.isEmpty)
}
#endif
