import Foundation
import Testing
@testable import StenoKit

private let notes = AppContext(bundleIdentifier: "com.apple.Notes", appName: "Notes")

private func expand(_ text: String, _ snippets: [Snippet], in app: AppContext = notes) async -> String {
    await SnippetService(snippets: snippets).apply(to: text, appContext: app)
}

@Test("A blank or whitespace-only trigger never fires")
func blankTriggersNeverFire() async {
    #expect(await expand("hello big world", [Snippet(trigger: " ", expansion: "X")]) == "hello big world")
    #expect(await expand("hello big world", [Snippet(trigger: "", expansion: "X")]) == "hello big world")
    #expect(await expand("hello\tbig world", [Snippet(trigger: " \t ", expansion: "X")]) == "hello\tbig world")
}

@Test("Triggers are trimmed before matching")
func triggersAreTrimmed() async {
    #expect(await expand("brb now", [Snippet(trigger: "brb ", expansion: "be right back")]) == "be right back now")
    #expect(await expand("ok brb", [Snippet(trigger: "  brb", expansion: "be right back")]) == "ok be right back")
}

@Test("The longest overlapping trigger wins whatever the saved order")
func longestOverlappingTriggerWins() async {
    let short = Snippet(trigger: "meeting", expansion: "team meeting")
    let long = Snippet(trigger: "meeting notes", expansion: "NOTES-TEMPLATE")
    #expect(await expand("start meeting notes now", [short, long]) == "start NOTES-TEMPLATE now")
    #expect(await expand("start meeting notes now", [long, short]) == "start NOTES-TEMPLATE now")
    #expect(await expand("one meeting, then meeting notes", [short, long])
        == "one team meeting, then NOTES-TEMPLATE")
}

@Test("An expansion is never expanded again")
func expansionsDoNotCascade() async {
    let signature = Snippet(trigger: "sig", expansion: "Thanks, brb")
    let brb = Snippet(trigger: "brb", expansion: "be right back")
    #expect(await expand("sig", [signature, brb]) == "Thanks, brb")
    #expect(await expand("sig", [brb, signature]) == "Thanks, brb")
    #expect(await expand("brb then sig", [brb, signature]) == "be right back then Thanks, brb")
}

@Test("An app shortcut beats an all-apps shortcut with the same trigger")
func appShortcutBeatsGlobal() async {
    let global = Snippet(trigger: "addr", expansion: "global address")
    let app = Snippet(trigger: "ADDR", expansion: "notes address", scope: .app(bundleID: "com.apple.Notes"))
    #expect(await expand("send addr", [global, app]) == "send notes address")
    #expect(await expand("send addr", [app, global]) == "send notes address")

    let mail = AppContext(bundleIdentifier: "com.apple.mail", appName: "Mail")
    #expect(await expand("send addr", [global, app], in: mail) == "send global address")
}

@Test("Triggers match whole words only, and expansions are inserted as written")
func triggersMatchWholeWords() async {
    #expect(await expand("the category concatenates scatter cat cats", [Snippet(trigger: "cat", expansion: "FELINE")])
        == "the category concatenates scatter FELINE cats")
    #expect(await expand("BRB. Brb, brb!", [Snippet(trigger: "brb", expansion: "be right back")])
        == "be right back. be right back, be right back!")
    #expect(await expand("please add ;sig here", [Snippet(trigger: ";sig", expansion: "SIGNATURE")])
        == "please add SIGNATURE here")
    #expect(await expand("pay brb", [Snippet(trigger: "brb", expansion: #"$1 \0 \\ done"#)])
        == #"pay $1 \0 \\ done"#)
}

@Test("The service rejects a shortcut whose trigger is blank")
func serviceRejectsBlankTrigger() async {
    let service = SnippetService()
    #expect(await service.upsert(Snippet(trigger: "   ", expansion: "X")) == false)
    #expect(await service.list().isEmpty)
    #expect(await service.upsert(Snippet(trigger: " brb ", expansion: "be right back")) == true)
    #expect(await service.list().map(\.trigger) == ["brb"])
    #expect(SnippetService.normalizedTrigger(" \t ") == nil)
    #expect(SnippetService.normalizedTrigger("  on my way ") == "on my way")
}
