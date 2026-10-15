import Foundation
import Testing
@testable import StenoKit

@Suite("Global shortcut")
struct GlobalShortcutTests {
    @Test("Saved text round-trips", arguments: [
        "control+option+command+9", "control+shift+9", "105", "option+command+0", "command+105",
    ])
    func roundTrip(saved: String) throws {
        let shortcut = try #require(GlobalShortcut(preferenceValue: saved))
        #expect(GlobalShortcut(preferenceValue: shortcut.preferenceValue) == shortcut)
    }

    @Test("Modifiers are saved in a fixed order")
    func canonicalOrder() throws {
        let shortcut = try #require(GlobalShortcut(preferenceValue: "command+control+9"))
        #expect(shortcut.preferenceValue == "control+command+9")
        #expect(shortcut.displayName == "⌃⌘V")
    }

    @Test("Letter keys name their letter for a menu, and other keys have none")
    func menuLetter() throws {
        #expect(try #require(GlobalShortcut(preferenceValue: "control+option+9")).letter == "v")
        #expect(try #require(GlobalShortcut(preferenceValue: "105")).letter == nil)
    }

    @Test("Function keys need no modifier and show their name")
    func functionKey() throws {
        let shortcut = try #require(GlobalShortcut(preferenceValue: "105"))
        #expect(shortcut.modifiers.isEmpty)
        #expect(shortcut.displayName == "F13")
    }

    @Test("Nothing saved, or text that can't be read, means no shortcut", arguments: [
        String?.none, "", "hyper+9", "command+", "command+V",
    ])
    func unassigned(saved: String?) {
        #expect(GlobalShortcut(preferenceValue: saved) == nil)
    }

    @Test("Chords that would collide or type text are refused", arguments: [
        // A modifier key itself, including the press-to-talk Option keys.
        ("58", GlobalShortcut.Problem.modifierKey), ("61", .modifierKey), ("command+55", .modifierKey),
        // A letter needs a modifier other than Shift.
        ("9", .needsModifier), ("shift+9", .needsModifier),
        // Option without Command or Control types a character, and holding it
        // starts press-to-talk.
        ("option+9", .optionNeedsCommandOrControl), ("option+shift+9", .optionNeedsCommandOrControl),
        ("option+105", .optionNeedsCommandOrControl),
        // Common system and app chords.
        ("command+9", .reserved), ("command+8", .reserved), ("command+12", .reserved),
        ("command+13", .reserved), ("command+48", .reserved), ("command+49", .reserved),
        ("command+7", .reserved), ("command+6", .reserved), ("shift+command+9", .reserved),
        ("control+49", .reserved), ("option+command+53", .reserved),
    ])
    func refused(saved: String, problem: GlobalShortcut.Problem) {
        #expect(GlobalShortcut(preferenceValue: saved) == nil)
        #expect(GlobalShortcut.problem(withPreferenceValue: saved) == problem)
    }

    @Test("The hands-free key is never a Paste Last Dictation shortcut, with or without modifiers")
    func handsFreeKeyCollides() throws {
        let f13 = try #require(GlobalShortcut(preferenceValue: "105"))
        let commandF13 = try #require(GlobalShortcut(preferenceValue: "command+105"))
        #expect(f13.collides(withHandsFreeKeyCode: 105))
        #expect(commandF13.collides(withHandsFreeKeyCode: 105))
        #expect(!f13.collides(withHandsFreeKeyCode: 79))
        #expect(!f13.collides(withHandsFreeKeyCode: nil))
        // F3 is one key with two codes.
        let f3 = try #require(GlobalShortcut(preferenceValue: "99"))
        #expect(f3.collides(withHandsFreeKeyCode: 160))
    }

    @Test("The filter fires once per press and keeps the key from the frontmost app")
    func filterFiresOnce() throws {
        var filter = GlobalShortcutFilter(shortcut: try #require(GlobalShortcut(preferenceValue: "control+option+command+9")))
        let mods: GlobalShortcut.Modifiers = [.control, .option, .command]

        let press = filter.handle(.keyDown(keyCode: 9, modifiers: mods, isRepeat: false))
        let repeated = filter.handle(.keyDown(keyCode: 9, modifiers: mods, isRepeat: true))
        let release = filter.handle(.keyUp(keyCode: 9))
        let strayRelease = filter.handle(.keyUp(keyCode: 9))

        #expect(press == .init(swallow: true, fire: true))
        #expect(repeated == .init(swallow: true, fire: false))
        #expect(release == .init(swallow: true, fire: false))
        #expect(strayRelease == .pass)
    }

    @Test("Other modifier combinations and keys pass through")
    func filterPassesOthers() throws {
        var filter = GlobalShortcutFilter(shortcut: try #require(GlobalShortcut(preferenceValue: "option+command+9")))
        let decisions = [
            filter.handle(.keyDown(keyCode: 9, modifiers: [.command], isRepeat: false)),
            filter.handle(.keyDown(keyCode: 9, modifiers: [.option, .command, .shift], isRepeat: false)),
            filter.handle(.keyDown(keyCode: 8, modifiers: [.option, .command], isRepeat: false)),
            filter.handle(.keyUp(keyCode: 9)),
        ]
        #expect(decisions.allSatisfy { $0 == .pass })
    }

    @Test("With no shortcut the filter passes everything")
    func filterWithoutShortcut() {
        var filter = GlobalShortcutFilter(shortcut: nil)
        let decision = filter.handle(.keyDown(keyCode: 105, modifiers: [], isRepeat: false))
        #expect(decision == .pass)
    }

    @Test("Auto-repeat of the held shortcut key stays swallowed after the modifiers are released or changed")
    func repeatIsSwallowedAfterModifiersChange() throws {
        var filter = GlobalShortcutFilter(shortcut: try #require(GlobalShortcut(preferenceValue: "control+option+9")))

        let press = filter.handle(.keyDown(keyCode: 9, modifiers: [.control, .option], isRepeat: false))
        #expect(press == .init(swallow: true, fire: true))
        // A stray key that was never held passes.
        #expect(filter.handle(.keyDown(keyCode: 0, modifiers: [], isRepeat: true)) == .pass)

        // Control and Option were lifted while the key is still held: repeats carry no modifiers.
        let repeatNoModifiers = filter.handle(.keyDown(keyCode: 9, modifiers: [], isRepeat: true))
        // Shift was added while the key is still held.
        let repeatExtraShift = filter.handle(.keyDown(keyCode: 9, modifiers: [.control, .option, .shift], isRepeat: true))
        let release = filter.handle(.keyUp(keyCode: 9))
        // After release, the same key without the modifiers is an ordinary key again.
        let freshPlainKey = filter.handle(.keyDown(keyCode: 9, modifiers: [], isRepeat: false))
        let strayRepeat = filter.handle(.keyDown(keyCode: 9, modifiers: [], isRepeat: true))

        #expect(repeatNoModifiers == .init(swallow: true, fire: false))
        #expect(repeatExtraShift == .init(swallow: true, fire: false))
        #expect(release == .init(swallow: true, fire: false))
        #expect(freshPlainKey == .pass)
        #expect(strayRepeat == .pass)
    }
}
