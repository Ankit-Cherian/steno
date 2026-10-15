import Foundation
import Testing
@testable import Steno

/// Preference writes land in the order they were requested, and the
/// success-notice count is written on top of what was last saved.
@MainActor
@Suite("Ordered preference writes")
struct OrderedPreferencesWriterTests {
    @Test("A slow earlier write still lands before a later one")
    func writesLandInRequestOrder() async {
        let recorder = WriteRecorder()
        let writer = OrderedPreferencesWriter(persisted: nil) { snapshot in
            await recorder.write(snapshot)
        }
        var first = AppPreferences.default
        first.dictation.threadCount = 4
        var second = AppPreferences.default
        second.dictation.threadCount = 8
        await recorder.holdNextWrite()

        let firstWrite = writer.enqueue(first)
        let secondWrite = writer.enqueue(second)
        try? await Task.sleep(for: .milliseconds(50))
        await recorder.releaseHeldWrite()
        _ = await (firstWrite.value, secondWrite.value)

        #expect(await recorder.threadCounts() == [4, 8])
    }

    @Test("The count is written on the last saved settings, never on a draft whose save failed")
    func countBuildsOnSavedSettings() async {
        let recorder = WriteRecorder()
        var saved = AppPreferences.default
        saved.dictation.threadCount = 6
        let writer = OrderedPreferencesWriter(persisted: saved) { snapshot in
            await recorder.write(snapshot)
        }
        var draft = saved
        draft.dictation.threadCount = 2
        await recorder.failNextWrite()
        _ = await writer.enqueue(draft).value

        _ = await writer.enqueueSuccessNoticeCount(5, fallback: draft).value

        let written = await recorder.written()
        #expect(written.last?.dictation.threadCount == 6)
        #expect(written.last?.general.successNoticesShown == 5)
    }

    @Test("A settings save requested after a count keeps the count and its own settings")
    func settingsAfterCount() async {
        let recorder = WriteRecorder()
        let writer = OrderedPreferencesWriter(persisted: .default) { snapshot in
            await recorder.write(snapshot)
        }
        await recorder.holdNextWrite()
        let count = writer.enqueueSuccessNoticeCount(3, fallback: .default)
        var settings = AppPreferences.default
        settings.general.successNoticesShown = 3
        settings.media.pauseDuringHandsFree = false
        let saved = writer.enqueue(settings)
        try? await Task.sleep(for: .milliseconds(50))
        await recorder.releaseHeldWrite()
        _ = await (count.value, saved.value)

        let last = await recorder.written().last
        #expect(last?.media.pauseDuringHandsFree == false)
        #expect(last?.general.successNoticesShown == 3)
    }
}

private actor WriteRecorder {
    private var writes: [AppPreferences] = []
    private var holdsNext = false
    private var failsNext = false
    private var held: CheckedContinuation<Void, Never>?

    func holdNextWrite() { holdsNext = true }
    func failNextWrite() { failsNext = true }
    func releaseHeldWrite() {
        holdsNext = false
        held?.resume()
        held = nil
    }

    func write(_ snapshot: AppPreferences) async -> Result<Void, AppPreferencesStoreError> {
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { held = $0 }
        }
        if failsNext {
            failsNext = false
            return .failure(.writeFailed)
        }
        writes.append(snapshot)
        return .success(())
    }

    func written() -> [AppPreferences] { writes }
    func threadCounts() -> [Int] { writes.map(\.dictation.threadCount) }
}
