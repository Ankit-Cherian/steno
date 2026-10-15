#if STENO_ACCEPTANCE
import AppKit
import Foundation

/// Lets an acceptance run exercise the system sleep path without sleeping the
/// Mac. A same-user process posts `notificationName` as a distributed
/// notification. This posts the system's own `NSWorkspace.willSleepNotification`
/// on the workspace center, so the app's real sleep observer runs, and nothing
/// here copies what that observer does.
///
/// The record of such a run is "sleep path exercised, not real sleep".
@MainActor
final class AcceptanceSleepTrigger {
    static let notificationName = Notification.Name("io.stenoapp.steno.acceptance.simulate-system-sleep")

    private let source: NotificationCenter
    private var observer: NSObjectProtocol?

    /// - Parameters:
    ///   - source: Where the request arrives. Distributed notifications only
    ///     reach processes of the same user.
    ///   - workspaceCenter: The center the app's sleep observer listens on.
    init(
        source: NotificationCenter = DistributedNotificationCenter.default(),
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.source = source
        observer = source.addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: .main
        ) { _ in
            workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        }
    }

    func stop() {
        if let observer { source.removeObserver(observer) }
        observer = nil
    }
}
#endif
