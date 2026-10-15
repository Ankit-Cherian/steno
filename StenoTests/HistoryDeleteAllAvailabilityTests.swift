import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Steno
import StenoKit

@Suite("Delete all history availability", .serialized)
@MainActor
struct HistoryDeleteAllAvailabilityTests {
    private struct Fixture {
        let directory: URL
        let historyURL: URL
        let controller: DictationController
    }

    private func makeFixture(historyData: Data?) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StenoHistoryDeleteAllAvailability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let historyURL = directory.appendingPathComponent("history.json")
        if let historyData {
            try historyData.write(to: historyURL)
        }
        let controller = makeTestDictationController(
            hotkey: DeleteAllTestHotkeyService(),
            historyStore: HistoryStore(storageURL: historyURL),
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("absent-legacy.json")
        )
        return Fixture(directory: directory, historyURL: historyURL, controller: controller)
    }

    /// Chooses Delete All History… in History's options menu and says whether its
    /// confirmation appeared, which a disabled item would not show.
    private func deleteAllOffersConfirmation(controller: DictationController) async throws -> Bool {
        let feedback = GroveFeedback()
        feedback.announce = { _ in }
        let host = TransitionHost(controller: controller) {
            GroveRenderHarness.window(.history, controller: controller, feedback: feedback) { GroveHistoryView() }
        }
        defer { host.close() }
        _ = await host.settle(timeout: .seconds(10)) { host.views(NSPopUpButton.self).contains { $0.menu?.indexOfItem(withTitle: "Delete All History…") ?? -1 >= 0 } }
        try await host.choose(menuItem: "Delete All History…")
        return await host.settle(timeout: .seconds(10)) { host.node(named: "Delete all History?") != nil }
    }

    @Test("Delete all history is available when the History file couldn't be read")
    func deleteAllAvailableForUnreadableHistory() async throws {
        let damaged = Data("[{\"rawText\": \"Fictional unreadable transcript\"".utf8)
        let fixture = try makeFixture(historyData: damaged)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { fixture.controller.teardown() }

        await fixture.controller.refreshHistory()
        #expect(fixture.controller.recentEntries.isEmpty)

        #expect(try await deleteAllOffersConfirmation(controller: fixture.controller))

        await HistoryRules.deleteAllHistory(using: fixture.controller)
        let remaining = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        for file in remaining where !file.lastPathComponent.hasPrefix(".") {
            let contents = try Data(contentsOf: file)
            #expect(contents.range(of: Data("Fictional unreadable transcript".utf8)) == nil, "\(file.lastPathComponent)")
        }
    }

    @Test("Delete all history stays available when the History list is empty")
    func deleteAllAvailableForEmptyHistory() async throws {
        let fixture = try makeFixture(historyData: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { fixture.controller.teardown() }

        await fixture.controller.refreshHistory()
        #expect(fixture.controller.recentEntries.isEmpty)

        #expect(try await deleteAllOffersConfirmation(controller: fixture.controller))
    }

    @Test("The Delete all confirmation names the dictations, or History when none are listed")
    func deleteAllConfirmationTitle() {
        #expect(HistoryRules.deleteAllConfirmationTitle(listedCount: 3) == "Delete all 3 dictations?")
        #expect(HistoryRules.deleteAllConfirmationTitle(listedCount: 0) == "Delete all History?")
    }

    @Test("After Delete all, no deleted transcript stays offered for copying")
    func deleteAllClearsTranscriptsHeldInMemory() async throws {
        let fixture = try makeFixture(historyData: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { fixture.controller.teardown() }
        fixture.controller.lastTranscript = "Fictional latest transcript"
        fixture.controller.storageNotice = StorageRecoveryNotice(
            message: "This transcript was copied but couldn't be saved to History.",
            fileURL: nil,
            recoverableText: "Fictional latest transcript"
        )

        await HistoryRules.deleteAllHistory(using: fixture.controller)

        #expect(fixture.controller.status == "History deleted.")
        #expect(fixture.controller.lastTranscript.isEmpty)
        #expect(fixture.controller.storageNotice == nil)
    }

    @Test("Delete all keeps a notice about another file that still exists")
    func deleteAllKeepsUnrelatedNotice() async throws {
        let fixture = try makeFixture(historyData: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { fixture.controller.teardown() }
        let preferencesCopy = fixture.directory.appendingPathComponent("preferences.original-20260101T120000Z.json")
        try Data("{}".utf8).write(to: preferencesCopy)
        let notice = StorageRecoveryNotice(
            message: "Some settings couldn't be read. Steno kept a copy of the original file.",
            fileURL: preferencesCopy
        )
        fixture.controller.storageNotice = notice

        await HistoryRules.deleteAllHistory(using: fixture.controller)

        #expect(fixture.controller.storageNotice == notice)
    }

    @Test("Delete all clears a notice about a kept History copy it removed")
    func deleteAllClearsNoticeAboutRemovedCopy() async throws {
        let fixture = try makeFixture(historyData: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { fixture.controller.teardown() }
        let keptCopy = fixture.directory.appendingPathComponent("history.unreadable-20260101T120000Z.json")
        try Data("Fictional damaged text".utf8).write(to: keptCopy)
        fixture.controller.storageNotice = StorageRecoveryNotice(
            message: "The transcript was deleted, but a damaged copy of the History file that Steno kept earlier still holds older text.",
            fileURL: keptCopy
        )

        await HistoryRules.deleteAllHistory(using: fixture.controller)

        #expect(!FileManager.default.fileExists(atPath: keptCopy.path))
        #expect(fixture.controller.storageNotice == nil)
    }
}

private final class DeleteAllTestHotkeyService: HotkeyService {
    var onPressToTalkStart: (() -> Void)?
    var onPressToTalkStop: (() -> Void)?
    var onToggleHandsFree: (() -> Void)?
    var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    var isOptionPressToTalkEnabled = true
    var globalToggleKeyCode: UInt16?

    func start() {}
    func stop() {}
}
