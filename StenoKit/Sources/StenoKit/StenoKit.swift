import Foundation

public enum StenoKitAssembly {
    public static func makeLocalFirstCoordinator(
        captureService: AudioCaptureService,
        transcriptionEngine: TranscriptionEngine,
        cleanupEngine: CleanupEngine,
        clipboardService: ClipboardService,
        directInsertion: InsertionTransport? = nil,
        accessibilityInsertion: InsertionTransport? = nil,
        historyStorageURL: URL? = nil
    ) -> SessionCoordinator {
        let historyStore = HistoryStore(storageURL: historyStorageURL, clipboardService: clipboardService)
        var transports: [any InsertionTransport] = []
        if let directInsertion {
            transports.append(directInsertion)
        }
        if let accessibilityInsertion {
            transports.append(accessibilityInsertion)
        }
        transports.append(ClipboardInsertionTransport(clipboard: clipboardService))

        let insertionService = InsertionService(transports: transports)
        let lexiconService = PersonalLexiconService()
        let styleService = StyleProfileService()
        let budgetGuard = BudgetGuard()

        return SessionCoordinator(
            captureService: captureService,
            transcriptionEngine: transcriptionEngine,
            cleanupEngine: cleanupEngine,
            insertionService: insertionService,
            historyStore: historyStore,
            lexiconService: lexiconService,
            styleProfileService: styleService,
            budgetGuard: budgetGuard
        )
    }
}
