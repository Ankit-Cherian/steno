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

@MainActor
@Test("Overlay routes Stop and Cancel independently and rejects disabled or blank regions")
func overlayHitTestingSupportsSeparateStopAndCancel() {
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
    let container = NSView(frame: CGRect(x: 70, y: 80, width: 440, height: 146))
    root.addSubview(container)
    let content = NSView(frame: container.bounds)
    container.addSubview(content)
    let stop = NSButton(frame: CGRect(x: 362, y: 107, width: 28, height: 28))
    let cancel = NSButton(frame: CGRect(x: 398, y: 107, width: 28, height: 28))
    content.addSubview(stop)
    content.addSubview(cancel)
    let stopPoint = CGPoint(x: 446, y: 201)
    let cancelPoint = CGPoint(x: 482, y: 201)
    #expect(OverlayHitTesting.interactiveView(at: stopPoint, in: container, interactiveViews: [stop, cancel]) === stop)
    #expect(OverlayHitTesting.interactiveView(at: cancelPoint, in: container, interactiveViews: [stop, cancel]) === cancel)
    #expect(OverlayHitTesting.interactiveView(at: CGPoint(x: 463, y: 201), in: container, interactiveViews: [stop, cancel]) == nil)
    #expect(OverlayHitTesting.interactiveView(at: CGPoint(x: 200, y: 125), in: container, interactiveViews: [stop, cancel]) == nil)
    stop.isEnabled = false
    cancel.isHidden = true
    #expect(OverlayHitTesting.interactiveView(at: stopPoint, in: container, interactiveViews: [stop, cancel]) == nil)
    #expect(OverlayHitTesting.interactiveView(at: cancelPoint, in: container, interactiveViews: [stop, cancel]) == nil)
}
#endif
