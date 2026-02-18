import Foundation

public struct ClosureInsertionTransport: InsertionTransport, Sendable {
    public let method: InsertionMethod
    private let block: @Sendable (String, AppContext) async throws -> Void

    public init(
        method: InsertionMethod,
        block: @escaping @Sendable (String, AppContext) async throws -> Void
    ) {
        self.method = method
        self.block = block
    }

    public func insert(text: String, target: AppContext) async throws {
        try await block(text, target)
    }
}
