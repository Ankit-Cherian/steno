import Foundation
import OSLog
import os

/// Times the steps of one insertion and writes them as one line to the Latency log, so a
/// dictation that was copied instead of inserted names what failed and how long each step
/// took. It records step names, durations and typed reasons, never text or which app was
/// involved: the line is public in the unified log.
/// Read with: log show --last 10m --predicate 'subsystem == "io.stenoapp.steno" AND category == "Latency"'
final class InsertionTrace: Sendable {
    @TaskLocal static var current: InsertionTrace?
    /// Receives each finished line as well as the log, for tests.
    @TaskLocal static var observer: (@Sendable (String) -> Void)?

    private static let logger = Logger(subsystem: "io.stenoapp.steno", category: "Latency")
    private let startedAt = ContinuousClock.now
    private let steps = OSAllocatedUnfairLock<[String]>(initialState: [])

    static func now() -> ContinuousClock.Instant { .now }

    /// Adds a step that began at `start` to the current insertion's line.
    static func note(_ step: String, since start: ContinuousClock.Instant) {
        guard let current else { return }
        let ms = milliseconds(from: start, to: .now)
        current.steps.withLock { $0.append("\(step) \(ms) ms") }
    }

    /// Runs one insertion with a trace, then logs its line.
    /// `hasTarget` is false for a copy that never tried the target.
    static func run(
        hasTarget: Bool,
        _ body: () async -> InsertResult
    ) async -> InsertResult {
        let trace = InsertionTrace()
        let result = await $current.withValue(trace) { await body() }
        let line = trace.line(for: result, hasTarget: hasTarget)
        logger.notice("\(line, privacy: .public)")
        observer?(line)
        return result
    }

    private func line(for result: InsertResult, hasTarget: Bool) -> String {
        let total = Self.milliseconds(from: startedAt, to: .now)
        let outcome: String
        switch result.status {
        case .inserted: outcome = "inserted"
        case .copiedOnly: outcome = result.pasteAttempted == true ? "pasted" : "copied"
        case .failed: outcome = "failed"
        case .noSpeech: outcome = "no speech"
        }
        let cause = result.copyReason.map { " (\($0.rawValue))" } ?? ""
        let recorded = steps.withLock { $0 }
        return "insertion \(outcome)\(cause) via \(result.method.rawValue) into \(hasTarget ? "target" : "no target") in \(total) ms: "
            + (recorded.isEmpty ? "no steps" : recorded.joined(separator: "; "))
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let duration = end - start
        return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    static func describe(_ check: Result<Void, EditorTargetUnavailableReason>) -> String {
        switch check {
        case .success: "ok"
        case .failure(let reason): "failed \(reason.rawValue)"
        }
    }

    /// A short typed name for a transport failure.
    static func describe(_ error: any Error) -> String {
        #if os(macOS)
        if let error = error as? MacInsertionError {
            switch error {
            case .eventSourceUnavailable: return "eventSourceUnavailable"
            case .accessibilityPermissionMissing: return "accessibilityPermissionMissing"
            case .focusedElementUnavailable: return "focusedElementUnavailable"
            case .unsupportedFocusedElement: return "unsupportedFocusedElement"
            case .attributeUpdateFailed: return "attributeUpdateFailed"
            case .exactTargetUnavailable(let reason): return reason.rawValue
            case .attributeUpdateIndeterminate: return "indeterminate"
            case .insertionRefused(let reason): return "refused \(reason.rawValue)"
            }
        }
        #endif
        if error is CancellationError { return "cancelled" }
        return String(describing: type(of: error))
    }
}
