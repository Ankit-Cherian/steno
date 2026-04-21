#if os(macOS)
import AppKit

enum OverlayHitTesting {
    @MainActor
    static func interactiveView(
        at point: NSPoint,
        in container: NSView,
        interactiveView: NSView?
    ) -> NSView? {
        guard let interactiveView,
              interactiveView.isDescendant(of: container),
              !interactiveView.isHiddenOrHasHiddenAncestor,
              let containerSuperview = container.superview else {
            return nil
        }

        // AppKit hitTest points arrive in the container's superview coordinates.
        let pointInContainer = container.convert(point, from: containerSuperview)
        let pointInInteractiveView = interactiveView.convert(pointInContainer, from: container)
        return interactiveView.bounds.contains(pointInInteractiveView) ? interactiveView : nil
    }
}
#endif
