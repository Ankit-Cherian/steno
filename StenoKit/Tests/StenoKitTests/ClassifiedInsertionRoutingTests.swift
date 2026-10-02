#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

@Test(
    "Apps classified from their bundle identifier get the insertion order live dictation uses",
    arguments: [
        ("com.microsoft.rdc.macos", "Windows App", true, InsertionMethod.clipboardPaste),
        ("com.apple.Terminal", "Terminal", false, InsertionMethod.clipboardPaste),
        ("com.googlecode.iterm2", "iTerm2", false, InsertionMethod.clipboardPaste),
        ("com.apple.TextEdit", "TextEdit", false, InsertionMethod.direct),
        ("com.microsoft.VSCode", "Code", false, InsertionMethod.direct),
    ]
)
func classifiedAppsGetLiveInsertionOrder(
    bundleID: String,
    appName: String,
    isRemoteDesktop: Bool,
    expectedMethod: InsertionMethod
) async {
    let target = AppContext.classified(bundleIdentifier: bundleID, appName: appName)
    #expect(target.isRemoteDesktop == isRemoteDesktop)

    let keys = FakeKeyPoster()
    let service = makeProductionInsertionService(
        clipboard: MemoryClipboardService(),
        keys: keys,
        activator: FakeApplicationActivator(frontmost: bundleID, running: [bundleID]),
        accessibility: FakeAccessibilityClient(focusedBundle: bundleID)
    )

    let result = await service.insert(text: "routed text", target: target)

    #expect(result.method == expectedMethod)
    if expectedMethod == .clipboardPaste {
        #expect(keys.typedText.isEmpty)
    } else {
        #expect(keys.typedText == ["routed text"])
    }
}
#endif
