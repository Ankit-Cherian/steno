import AppKit
import StenoKit
import SwiftUI
import Testing
@testable import Steno

/// A usage store a test steers: it can hold a read, fail it, or answer with a snapshot.
actor ScriptedUsageStore: UsageAnalyticsStoreServicing {
    private var snapshot: UsageAnalyticsSnapshot
    private var failing = false
    private var held = false

    init(snapshot: UsageAnalyticsSnapshot) { self.snapshot = snapshot }

    func set(_ snapshot: UsageAnalyticsSnapshot) { self.snapshot = snapshot }
    func fail(_ on: Bool) { failing = on }
    func hold() { held = true }
    func release() { held = false }

    func record(event: UsageEvent) async throws {}
    func recoverCorruptArchiveIfNeeded() async throws -> URL? { nil }
    func reconcileHistory(legacyURL: URL?, currentEntries: [TranscriptEntry]) async throws -> String? { nil }

    func snapshot(now: Date, calendar: Calendar, months: Int) async throws -> UsageAnalyticsSnapshot {
        while held { try await Task.sleep(for: .milliseconds(5)) }
        if failing { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }
}

/// Insights reading a real controller: loading, a failed read and Try Again, no usage yet, a
/// warning over the page, the apps, and a calendar that says at rest that its days can be chosen.
@Suite("Insights coverage transitions", .serialized)
@MainActor
struct InsightsCoverageTransitionTests {
    typealias F = TransitionFixtures

    private func session(_ store: ScriptedUsageStore) -> DictationController {
        makeTestDictationController(hotkey: TransitionHotkey(), usageAnalyticsStore: store)
    }

    private func host(_ controller: DictationController) -> TransitionHost {
        TransitionHost(controller: controller) {
            GroveRenderHarness.window(.insights, controller: controller) { GroveInsightsView() }
        }
    }

    private func says(_ host: TransitionHost, _ prefix: String) -> Bool {
        host.node { $0.text.hasPrefix(prefix) } != nil
    }

    private func isLoaded(_ host: TransitionHost) -> Bool { host.node(named: "The last six months") != nil }

    @Test("While the usage file is read Insights says so, and the page replaces it when the read lands")
    func loadingThenLoaded() async throws {
        let store = ScriptedUsageStore(snapshot: WindowSampleData.usageSnapshot())
        await store.hold()
        let controller = session(store)
        defer { controller.teardown() }
        let host = host(controller)
        defer { host.close() }
        #expect(await host.settle { says(host, "Loading usage…") }, "\(host.names())")
        await store.release()
        #expect(await host.settle { isLoaded(host) }, "the page never came: \(host.names())")
        #expect(!says(host, "Loading usage…"))
    }

    @Test("A failed read says Insights couldn’t load, and Try Again loads the page once the file reads")
    func errorThenTryAgain() async throws {
        let store = ScriptedUsageStore(snapshot: WindowSampleData.usageSnapshot())
        await store.fail(true)
        let controller = session(store)
        defer { controller.teardown() }
        let host = host(controller)
        defer { host.close() }
        #expect(await host.settle { says(host, "Insights couldn’t load") }, "\(host.names())")
        #expect(says(host, "The usage file couldn’t be read. History isn’t affected."))

        await store.fail(false)
        try await host.press("Try Again")
        #expect(await host.settle { isLoaded(host) }, "Try Again left \(host.names())")
        #expect(!says(host, "Insights couldn’t load"))
    }

    @Test("With no dictation counted yet Insights says how it fills, and fills when one is")
    func emptyThenFilled() async throws {
        let store = ScriptedUsageStore(snapshot: WindowSampleData.usageSnapshot(weeks: []))
        let controller = session(store)
        defer { controller.teardown() }
        let host = host(controller)
        defer { host.close() }
        #expect(await host.settle { says(host, "No usage yet") }, "\(host.names())")
        #expect(says(host, "Totals and the calendar fill in after your first dictation."))

        controller.usageAnalyticsSnapshot = WindowSampleData.usageSnapshot()
        #expect(await host.settle { isLoaded(host) })
    }

    @Test("A warning about the usage file sits above the page, which still shows")
    func warningOverThePage() async throws {
        let controller = F.sampleController()
        controller.usageAnalyticsWriteWarning = "The last dictation couldn’t be counted in Insights."
        let host = host(controller)
        defer { host.close() }
        #expect(await host.settle { isLoaded(host) })
        #expect(says(host, "The last dictation couldn’t be counted in Insights."))
    }

    @Test("Where your words went names each app with its words and share, or says none were counted")
    func appRows() async throws {
        let controller = F.sampleController()
        let host = host(controller)
        defer { host.close() }
        #expect(await host.settle { isLoaded(host) })
        let apps = InsightsData.appUsage(controller.usageAnalyticsSnapshot)
        let top = try #require(apps.first)
        let name = AppNames.name(for: top.appBundleID)
        let row = host.node { $0.name.hasPrefix(name + ", ") }
        #expect(row?.name.contains(GroveInsightsSummary.wordsText(top.wordCount)) == true, "row: \(row?.name ?? "none")")
        #expect(row?.name.hasSuffix("%") == true)

        var snapshot = controller.usageAnalyticsSnapshot
        snapshot.topApps = []
        controller.usageAnalyticsSnapshot = snapshot
        #expect(await host.settle { says(host, "No words counted yet.") }, "\(host.names().suffix(6))")
    }

    @Test("At rest the calendar says its days can be chosen, and the line becomes the chosen day")
    func calendarSaysItCanBeChosen() async throws {
        let host = host(F.sampleController())
        defer { host.close() }
        await host.settle { !InsightsTransitionTests.cells(host).isEmpty }
        let hint = "Choose a day to see how much you dictated."
        #expect(says(host, hint), "nothing at rest says a day can be chosen: \(host.names().filter { !$0.contains(", 20") }.prefix(12))")

        let cell = try #require(InsightsTransitionTests.cells(host).last { $0.accessibilityLabel()?.contains(" words") == true })
        let date = try #require(InsightsTransitionTests.date(of: cell))
        #expect(cell.accessibilityPerformPress())
        #expect(await host.settle { InsightsTransitionTests.chosenLine(host, for: date) != nil })
        #expect(!says(host, hint), "the hint stayed after a day was chosen")
    }
}
