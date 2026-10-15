import Foundation

/// Hands each input level from the recording's meter to every surface that draws it: the overlay
/// (through the controller), the recording plate's quill on Today and the menu bar icon.
///
/// It is not observable. A level arrives up to 30 times a second, so consumers write straight to a
/// layer or an image and never publish it through view state.
@MainActor
final class InputLevelBroadcast {
    typealias Consumer = @MainActor (Float) -> Void

    private var consumers: [UUID: Consumer] = [:]

    /// Calls `consumer` for every level until `remove(_:)`. Returns the token to remove it with.
    func add(_ consumer: @escaping Consumer) -> UUID {
        let token = UUID()
        consumers[token] = consumer
        return token
    }

    func remove(_ token: UUID) {
        consumers[token] = nil
    }

    func send(_ level: Float) {
        for consumer in consumers.values { consumer(level) }
    }
}
