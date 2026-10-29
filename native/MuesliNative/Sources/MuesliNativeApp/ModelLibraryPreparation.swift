import Foundation

/// Transfers remain independent; only memory-heavy library validation is serialized.
actor ModelLibraryPreparation {
    static let shared = ModelLibraryPreparation()
    private let gate = InferenceGate()

    func run(
        download: () async throws -> Void,
        onQueued: (@Sendable () -> Void)? = nil,
        prepare: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await download()
        try await gate.acquire(onWait: onQueued)
        do {
            // A queued caller can be cancelled just as the permit is handed over.
            try Task.checkCancellation()
            try await prepare()
            try Task.checkCancellation()
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }
}
