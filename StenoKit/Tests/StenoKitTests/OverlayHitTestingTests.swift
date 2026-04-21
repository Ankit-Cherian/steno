#if os(macOS)
import AppKit
import Testing
@testable import StenoKit

@MainActor
@Test("Overlay hit testing resolves the interactive button from nested overlay content")
func overlayHitTestingReturnsInteractiveButtonForNestedContent() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    let container = NSView(frame: NSRect(x: 20, y: 10, width: 292, height: 52))
    root.addSubview(container)

    let content = NSView(frame: container.bounds)
    container.addSubview(content)

    let button = NSButton(frame: NSRect(x: 252, y: 14, width: 24, height: 24))
    content.addSubview(button)

    let pointInRoot = NSPoint(x: 284, y: 36)
    let hit = OverlayHitTesting.interactiveView(
        at: pointInRoot,
        in: container,
        interactiveView: button
    )

    #expect(hit === button)
}

@MainActor
@Test("Overlay hit testing ignores points outside the interactive button")
func overlayHitTestingIgnoresPointsOutsideInteractiveButton() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    let container = NSView(frame: NSRect(x: 20, y: 10, width: 292, height: 52))
    root.addSubview(container)

    let content = NSView(frame: container.bounds)
    container.addSubview(content)

    let button = NSButton(frame: NSRect(x: 252, y: 14, width: 24, height: 24))
    content.addSubview(button)

    let pointInRoot = NSPoint(x: 100, y: 20)
    let hit = OverlayHitTesting.interactiveView(
        at: pointInRoot,
        in: container,
        interactiveView: button
    )

    #expect(hit == nil)
}

@MainActor
@Test("Overlay hit testing ignores hidden interactive buttons")
func overlayHitTestingIgnoresHiddenButtons() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
    let container = NSView(frame: NSRect(x: 20, y: 10, width: 292, height: 52))
    root.addSubview(container)

    let content = NSView(frame: container.bounds)
    container.addSubview(content)

    let button = NSButton(frame: NSRect(x: 252, y: 14, width: 24, height: 24))
    button.isHidden = true
    content.addSubview(button)

    let pointInRoot = NSPoint(x: 284, y: 36)
    let hit = OverlayHitTesting.interactiveView(
        at: pointInRoot,
        in: container,
        interactiveView: button
    )

    #expect(hit == nil)
}
#endif
