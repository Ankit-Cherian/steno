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
            historyStore: HistoryStore(storageURL: historyURL, clipboardService: MemoryClipboardService()),
            usageAnalyticsStore: UsageAnalyticsStore(storageURL: directory.appendingPathComponent("usage.json")),
            legacyHistoryURL: directory.appendingPathComponent("absent-legacy.json")
        )
        return Fixture(directory: directory, historyURL: historyURL, controller: controller)
    }

    /// Renders the History tab and returns the pixels of the right half of
    /// its header row, where the Delete all button sits. A disabled button
    /// draws with different fill, border and text colors.
    private func deleteAllHeaderPixels(controller: DictationController) async throws -> [UInt8] {
        AppFontRegistry.registerIfNeeded()
        let size = CGSize(width: StenoDesign.windowIdealWidth, height: StenoDesign.windowIdealHeight)
        let theme = StenoDesign.theme(for: controller.preferences)
        let hosting = NSHostingView(rootView: HistoryTab()
            .environmentObject(controller)
            .foregroundStyle(theme.text)
            .background(theme.ink0)
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.bitmapData)
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let rows = Int(70 * scale)
        let firstColumn = bitmap.pixelsWide / 2
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        var pixels: [UInt8] = []
        for row in 0..<rows {
            let rowStart = row * bitmap.bytesPerRow
            let start = rowStart + firstColumn * bytesPerPixel
            let end = rowStart + bitmap.pixelsWide * bytesPerPixel
            pixels.append(contentsOf: UnsafeBufferPointer(start: data + start, count: end - start))
        }
        return pixels
    }

    /// The header as drawn with a saved transcript listed, when the button
    /// has always been available.
    private func headerPixelsWithListedTranscript() async throws -> [UInt8] {
        let entry = TranscriptEntry(
            appBundleID: "com.example.Editor",
            rawText: "fictional listed note",
            cleanText: "Fictional listed note.",
            durationMS: 2_000,
            audioURL: nil,
            insertionStatus: .inserted
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fixture = try makeFixture(historyData: try encoder.encode([entry]))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { fixture.controller.teardown() }
        await fixture.controller.refreshHistory()
        #expect(fixture.controller.recentEntries.count == 1)
        return try await deleteAllHeaderPixels(controller: fixture.controller)
    }

    @Test("Delete all history is available when the History file couldn't be read")
    func deleteAllAvailableForUnreadableHistory() async throws {
        let damaged = Data("[{\"rawText\": \"Fictional unreadable transcript\"".utf8)
        let fixture = try makeFixture(historyData: damaged)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { fixture.controller.teardown() }

        await fixture.controller.refreshHistory()
        #expect(fixture.controller.recentEntries.isEmpty)

        let available = try await headerPixelsWithListedTranscript()
        #expect(try await deleteAllHeaderPixels(controller: fixture.controller) == available)

        await HistoryTab.deleteAllHistory(using: fixture.controller)
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

        let available = try await headerPixelsWithListedTranscript()
        #expect(try await deleteAllHeaderPixels(controller: fixture.controller) == available)
    }

    @Test("The Delete all confirmation names the transcripts, or History when none are listed")
    func deleteAllConfirmationTitle() {
        #expect(HistoryTab.deleteAllConfirmationTitle(listedCount: 3) == "Delete all 3 transcripts?")
        #expect(HistoryTab.deleteAllConfirmationTitle(listedCount: 0) == "Delete all history?")
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

        await HistoryTab.deleteAllHistory(using: fixture.controller)

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

        await HistoryTab.deleteAllHistory(using: fixture.controller)

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

        await HistoryTab.deleteAllHistory(using: fixture.controller)

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
