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
#endif
