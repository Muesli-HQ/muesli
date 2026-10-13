import ApplicationServices
import CoreFoundation
import Foundation

private let computerUseAccessibilityNoopCallback: AXObserverCallback = { _, _, _, _ in }

enum ComputerUseAccessibilityKeepAlive {
    private struct AssertionFailure {
        var retryAfter: Date
        var attempts: Int
    }

    private typealias RemoteAddNotificationFn = @convention(c) (
        AXObserver,
        AXUIElement,
        CFString,
        UnsafeMutableRawPointer?
    ) -> AXError

    private static let lock = NSLock()
    private static var assertedPIDs = Set<pid_t>()
    private static var assertionFailures: [pid_t: AssertionFailure] = [:]
    private static var observerPIDs = Set<pid_t>()
    private static var observers: [pid_t: AXObserver] = [:]
    private static let assertionRetryBaseDelay: TimeInterval = 0.5
    private static let assertionRetryMaxDelay: TimeInterval = 8.0

    private static let remoteAddNotification: RemoteAddNotificationFn? = {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "AXObserverAddNotificationAndCheckRemote"
        ) else {
            return nil
        }
        return unsafeBitCast(symbol, to: RemoteAddNotificationFn.self)
    }()

    static func assertForSnapshot(processID: pid_t, root: AXUIElement) {
        guard processID > 0 else { return }
        let accepted = assertAccessibilityAttributes(processID: processID, root: root)
        guard accepted else { return }
        if registerObserverIfNeeded(processID: processID) {
            pumpRunLoop(duration: 0.25)
        }
    }

    private static func assertAccessibilityAttributes(processID: pid_t, root: AXUIElement) -> Bool {
        let now = Date()
        lock.lock()
        if let failure = assertionFailures[processID],
           failure.retryAfter > now {
            let alreadyAsserted = assertedPIDs.contains(processID)
            lock.unlock()
            return alreadyAsserted
        }
        lock.unlock()

        let manual = AXUIElementSetAttributeValue(
            root,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        let enhanced = AXUIElementSetAttributeValue(
            root,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )

        lock.lock()
        defer { lock.unlock() }
        if manual == .success || enhanced == .success {
            assertedPIDs.insert(processID)
            assertionFailures.removeValue(forKey: processID)
            return true
        }
        guard !assertedPIDs.contains(processID) else {
            return true
        }
        let attempts = min((assertionFailures[processID]?.attempts ?? 0) + 1, 6)
        let delay = min(
            assertionRetryMaxDelay,
            assertionRetryBaseDelay * pow(2.0, Double(attempts - 1))
        )
        assertionFailures[processID] = AssertionFailure(
            retryAfter: Date().addingTimeInterval(delay),
            attempts: attempts
        )
        return false
    }

    private static func registerObserverIfNeeded(processID: pid_t) -> Bool {
        lock.lock()
        if observerPIDs.contains(processID) {
            lock.unlock()
            return false
        }
        observerPIDs.insert(processID)
        lock.unlock()

        var observer: AXObserver?
        guard AXObserverCreate(processID, computerUseAccessibilityNoopCallback, &observer) == .success,
              let observer else {
            lock.lock()
            observerPIDs.remove(processID)
            lock.unlock()
            return false
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let root = AXUIElementCreateApplication(processID)
        for notification in notifications {
            _ = addNotification(observer: observer, element: root, notification: notification)
        }

        lock.lock()
        observers[processID] = observer
        lock.unlock()
        return true
    }

    private static func addNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: CFString
    ) -> AXError {
        if let remoteAddNotification {
            return remoteAddNotification(observer, element, notification, nil)
        }
        return AXObserverAddNotification(observer, element, notification, nil)
    }

    private static func pumpRunLoop(duration: CFTimeInterval) {
        let end = CFAbsoluteTimeGetCurrent() + duration
        while CFAbsoluteTimeGetCurrent() < end {
            let remaining = max(0.01, end - CFAbsoluteTimeGetCurrent())
            _ = CFRunLoopRunInMode(.defaultMode, remaining, false)
        }
    }

    private static let notifications: [CFString] = [
        kAXFocusedUIElementChangedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXApplicationActivatedNotification as CFString,
        kAXApplicationDeactivatedNotification as CFString,
        kAXApplicationHiddenNotification as CFString,
        kAXApplicationShownNotification as CFString,
        kAXWindowCreatedNotification as CFString,
        kAXWindowMovedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXValueChangedNotification as CFString,
        kAXTitleChangedNotification as CFString,
        kAXSelectedChildrenChangedNotification as CFString,
        kAXLayoutChangedNotification as CFString,
    ]
}
