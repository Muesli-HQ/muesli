import ApplicationServices
import CoreFoundation
import Foundation

private let computerUseAccessibilityNoopCallback: AXObserverCallback = { _, _, _, _ in }

enum ComputerUseAccessibilityKeepAlive {
    private typealias RemoteAddNotificationFn = @convention(c) (
        AXObserver,
        AXUIElement,
        CFString,
        UnsafeMutableRawPointer?
    ) -> AXError

    private static let lock = NSLock()
    private static var assertedPIDs = Set<pid_t>()
    private static var nonAssertablePIDs = Set<pid_t>()
    private static var observerPIDs = Set<pid_t>()
    private static var observers: [pid_t: AXObserver] = [:]

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
        lock.lock()
        if nonAssertablePIDs.contains(processID) {
            lock.unlock()
            return false
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
            return true
        }
        if !assertedPIDs.contains(processID) {
            nonAssertablePIDs.insert(processID)
        }
        return assertedPIDs.contains(processID)
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
