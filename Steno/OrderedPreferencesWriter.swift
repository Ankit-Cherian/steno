import Foundation

/// Writes preferences one after another, in the order the writes were
/// requested, so an earlier snapshot never lands after a later one.
///
/// The success-notice count changes with dictations rather than Settings. It
/// is written on top of the last snapshot that was saved, so it never
/// carries along settings whose own save failed or is still pending.
@MainActor
final class OrderedPreferencesWriter {
    typealias Write = @Sendable (AppPreferences) async -> Result<Void, AppPreferencesStoreError>

    private let write: Write
    private var tail: Task<Void, Never>?
    /// The last snapshot written successfully, or the one loaded at launch.
    private(set) var persisted: AppPreferences?

    init(persisted: AppPreferences?, write: @escaping Write) {
        self.persisted = persisted
        self.write = write
    }

    /// Queues `snapshot` behind every write requested before it.
    func enqueue(_ snapshot: AppPreferences) -> Task<Result<Void, AppPreferencesStoreError>, Never> {
        enqueue { _ in snapshot }
    }

    /// Queues the count, applied to the last saved snapshot when it is written.
    /// `fallback` is used only when nothing has been loaded or saved yet.
    func enqueueSuccessNoticeCount(
        _ count: Int,
        fallback: AppPreferences
    ) -> Task<Result<Void, AppPreferencesStoreError>, Never> {
        enqueue { persisted in
            var snapshot = persisted ?? fallback
            snapshot.general.successNoticesShown = count
            return snapshot
        }
    }

    /// Records a snapshot that is known to be on disk, such as the one loaded at launch.
    func markPersisted(_ snapshot: AppPreferences) {
        persisted = snapshot
    }

    private func enqueue(
        _ makeSnapshot: @escaping @MainActor (AppPreferences?) -> AppPreferences
    ) -> Task<Result<Void, AppPreferencesStoreError>, Never> {
        let previous = tail
        let write = self.write
        let task = Task { @MainActor [weak self] () -> Result<Void, AppPreferencesStoreError> in
            await previous?.value
            let snapshot = makeSnapshot(self?.persisted)
            let result = await write(snapshot)
            if case .success = result {
                self?.persisted = snapshot
            }
            return result
        }
        tail = Task { _ = await task.value }
        return task
    }
}
