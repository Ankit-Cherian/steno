#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

@Test("The transport factory keeps the configured order and always ends with clipboard recovery")
func insertionFactoryKeepsConfiguredOrder() {
    let system = makeFakeInsertionSystem(
        keys: FakeKeyPoster(),
        activator: FakeApplicationActivator(),
        accessibility: FakeAccessibilityClient()
    )
    let clipboard = MemoryClipboardService()

    let defaults = MacInsertionTransportFactory.makeTransports(
        orderedMethods: defaultInsertionOrder,
        clipboard: clipboard,
        system: system
    )
    #expect(defaults.map(\.method) == [.direct, .accessibility, .clipboardPaste])

    let withoutClipboard = MacInsertionTransportFactory.makeTransports(
        orderedMethods: [.accessibility, .none, .direct],
        clipboard: clipboard,
        system: system
    )
    #expect(withoutClipboard.map(\.method) == [.accessibility, .direct, .clipboardPaste])
}

@Test("Default settings type into the target app when it is frontmost")
func productionPathTypesIntoFrontmostTarget() async {
    let keys = FakeKeyPoster()
    let clipboard = MemoryClipboardService()
    let service = makeProductionInsertionService(
        clipboard: clipboard,
        keys: keys,
        activator: FakeApplicationActivator(),
        accessibility: FakeAccessibilityClient()
    )

    let result = await service.insert(text: "hello there", target: productionPathContext)

    #expect(result.status == .inserted)
    #expect(result.method == .direct)
    #expect(keys.typedText == ["hello there"])
    #expect(await clipboard.latestValue == "")
}

@Test("Default settings copy instead of typing when the target app can't be brought to the front")
func productionPathCopiesWhenTargetAppIsNotFrontmost() async {
    let keys = FakeKeyPoster()
    let clipboard = MemoryClipboardService()
    let activator = FakeApplicationActivator()
    let accessibility = FakeAccessibilityClient()
    // The user switched to Notes during transcription, and macOS declines to
    // bring the original app back.
    activator.switchToOtherApp("com.apple.Notes", targetRefusesActivation: true)
    accessibility.focusOtherApp("com.apple.Notes")
    let service = makeProductionInsertionService(
        clipboard: clipboard,
        keys: keys,
        activator: activator,
        accessibility: accessibility
    )

    let result = await service.insert(text: "meant for the editor", target: productionPathContext)

    #expect(result.status == .copiedOnly)
    #expect(result.method == .clipboardPaste)
    #expect(keys.events.isEmpty)
    #expect(accessibility.writes.isEmpty)
    #expect(await clipboard.latestValue == "meant for the editor")
}

@Test("Default settings copy instead of typing when the target app has quit")
func productionPathCopiesWhenTargetAppQuit() async {
    let keys = FakeKeyPoster()
    let clipboard = MemoryClipboardService()
    let activator = FakeApplicationActivator(frontmost: "com.apple.Notes", running: ["com.apple.Notes"])
    let accessibility = FakeAccessibilityClient(focusedBundle: "com.apple.Notes")
    let service = makeProductionInsertionService(
        clipboard: clipboard,
        keys: keys,
        activator: activator,
        accessibility: accessibility
    )

    let result = await service.insert(text: "meant for the editor", target: productionPathContext)

    #expect(result.status == .copiedOnly)
    #expect(keys.events.isEmpty)
    #expect(accessibility.writes.isEmpty)
    #expect(await clipboard.latestValue == "meant for the editor")
}
#endif

#if os(macOS)
@Test("Remote-desktop targets paste through the clipboard before typing")
func remoteDesktopTargetsPasteFirst() async {
    let remote = AppContext(
        bundleIdentifier: "com.microsoft.rdc.macos",
        appName: "Microsoft Remote Desktop",
        isRemoteDesktop: true
    )
    let keys = FakeKeyPoster()
    let service = makeProductionInsertionService(
        clipboard: MemoryClipboardService(),
        keys: keys,
        activator: FakeApplicationActivator(
            frontmost: remote.bundleIdentifier,
            running: [remote.bundleIdentifier]
        ),
        accessibility: FakeAccessibilityClient(focusedBundle: remote.bundleIdentifier)
    )

    let result = await service.insert(text: "remote text", target: remote)

    #expect(result.method == .clipboardPaste)
    #expect(result.pasteAttempted == true)
    #expect(keys.typedText.isEmpty)
    #expect(keys.commandShortcuts.count == 1)
}
#endif

#if os(macOS)
@Test("A slow app's Accessibility timeout is reported as a timeout, not a target change")
func exactTargetTimeoutIsReportedAsTimeout() async throws {
    let keys = FakeKeyPoster()
    let accessibility = FakeAccessibilityClient()
    let pasteboard = FakePasteboard()
    let service = makeProductionInsertionService(
        clipboard: pasteboard,
        keys: keys,
        activator: FakeApplicationActivator(),
        accessibility: accessibility
    )
    let handle = try EditorTargetHandle.capture(
        target: productionPathContext,
        client: accessibility
    ).get()
    accessibility.failCaptures(with: .timedOut)

    let result = await service.insert(
        text: "slow app",
        target: productionPathContext,
        editorTarget: handle,
        clipboardRecoveryText: "slow app",
        commitAuthorization: InsertionCommitAuthorization()
    )

    #expect(result.status == .copiedOnly)
    #expect(keys.events.isEmpty)
    #expect(result.errorMessage?.localizedCaseInsensitiveContains("respond in time") == true)
    #expect(result.errorMessage?.localizedCaseInsensitiveContains("target changed") == false)
    #expect(pasteboard.plainText == "slow app")
}
#endif
