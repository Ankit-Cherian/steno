import AppKit
import Combine
import SwiftUI

/// The text size chosen in System Settings › Accessibility › Display › Text Size, as a SwiftUI
/// text-size step. SwiftUI does not pass that setting to a Mac window, so the windows read the
/// body font's size as the island does, and follow it. The setting is read again whenever Steno
/// becomes the active app, which is how a person comes back from changing it.
@MainActor
final class SystemTextSize: ObservableObject {
    static let shared = SystemTextSize()

    /// The body size at the default setting.
    nonisolated static let baselineBodyPointSize: CGFloat = 13

    @Published private(set) var dynamicTypeSize: DynamicTypeSize
    private let read: @MainActor () -> CGFloat
    private var activation: AnyCancellable?

    init(read: @escaping @MainActor () -> CGFloat = { NSFont.preferredFont(forTextStyle: .body).pointSize },
         notificationCenter: NotificationCenter = .default) {
        self.read = read
        dynamicTypeSize = Self.step(forBodyPointSize: read())
        activation = notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func refresh() {
        let step = Self.step(forBodyPointSize: read())
        if step != dynamicTypeSize { dynamicTypeSize = step }
    }

    /// The step whose scale is nearest the body size's, never below the default: like the island,
    /// the windows grow with a larger setting and keep their size with a smaller one.
    nonisolated static func step(forBodyPointSize size: CGFloat) -> DynamicTypeSize {
        let ratio = size / baselineBodyPointSize
        let steps = DynamicTypeSize.allCases.filter { $0 >= .large }
        return steps.min { abs(QuillType.scale(for: $0) - ratio) < abs(QuillType.scale(for: $1) - ratio) } ?? .large
    }
}

extension EnvironmentValues {
    /// Where a window reads the system text size, when not the shared reader. Tests put a fixed
    /// one here.
    @Entry var systemTextSize: SystemTextSize?
}

/// Sets the text size of a window's content to the larger of the size already in effect and the
/// system setting, so a size set further out, as a test does, still holds.
private struct FollowsSystemTextSize: ViewModifier {
    @Environment(\.systemTextSize) private var source

    func body(content: Content) -> some View {
        Applied(source: source ?? .shared, content: content)
    }

    private struct Applied: View {
        @ObservedObject var source: SystemTextSize
        let content: Content
        @Environment(\.dynamicTypeSize) private var outer

        var body: some View {
            content.dynamicTypeSize(max(outer, source.dynamicTypeSize))
        }
    }
}

extension View {
    /// Follows the text size set in System Settings.
    func followsSystemTextSize() -> some View {
        modifier(FollowsSystemTextSize())
    }
}
