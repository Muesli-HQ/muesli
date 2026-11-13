import Foundation
import MuesliCore

@MainActor
func privateContentTask<T: Sendable>(session: ContentPrivacy.Session,
    operation: @escaping @MainActor @Sendable () async -> T) -> Task<T, Never> {
    Task { await ContentPrivacy.$session.withValue(session) { await operation() } }
}
