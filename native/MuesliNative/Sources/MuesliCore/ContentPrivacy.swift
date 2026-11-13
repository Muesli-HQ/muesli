import Foundation

/// Local content retention policy. Independent of anonymous event consent.
public final class ContentPrivacy: @unchecked Sendable {
    public static let preferenceKey = "muesli.privateMode"
    public static let shared = ContentPrivacy(enabled: UserDefaults.standard.bool(forKey: preferenceKey))
    public struct Session: Sendable { let epoch: UUID; fileprivate let ephemeral: Bool }
    @TaskLocal public static var session: Session?
    public enum Failure: Error { case ephemeralContent }
    private let lock = NSCondition()
    private var activeWrites = 0
    private var enabled: Bool
    private var epoch = UUID()
    private var redactsLogs: Bool
    public init(enabled: Bool = false) { self.enabled = enabled; redactsLogs = enabled }
    public var isEnabled: Bool { lock.withLock { enabled } }
    public var mayLogContent: Bool { lock.withLock { !redactsLogs } }
    public func logDescription(_ error: Error) -> String {
        mayLogContent ? String(describing: error) : String(describing: type(of: error))
    }
    public func capture() -> Session { lock.withLock { Session(epoch: epoch, ephemeral: enabled) } }
    public func permits(_ session: Session?) -> Bool {
        lock.withLock { permitsUnlocked(session) }
    }
    private func permitsUnlocked(_ session: Session?) -> Bool {
        !enabled && session.map { !$0.ephemeral && $0.epoch == epoch } != false
    }
    public func setEnabled(_ value: Bool) {
        lock.withLock {
            guard enabled != value else { return }
            enabled = value
            if value {
                epoch = UUID(); redactsLogs = true
            }
        }
    }
    /// Writers do not serialize against other writers or hold the policy lock
    /// during disk work. Enabling revokes new admissions immediately.
    public func beginWrite(_ session: Session? = ContentPrivacy.session) throws {
        try lock.withLock {
            guard permitsUnlocked(session) else { throw Failure.ephemeralContent }
            activeWrites += 1
        }
    }
    /// Background synchronization point for callers that must observe completed writes.
    public func waitForAdmittedWrites() {
        lock.withLock { while activeWrites > 0 { lock.wait() } }
    }
    public func endWrite() {
        lock.withLock { activeWrites -= 1; if activeWrites == 0 { lock.broadcast() } }
    }
}
