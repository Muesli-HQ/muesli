import AppKit
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

enum ComputerUseBackgroundDriver {
    enum MouseButton {
        case left
        case right
    }

    static var focusWithoutRaiseForTests: ((pid_t, CGWindowID) -> Bool)?

    @discardableResult
    static func postKeyEvent(_ event: CGEvent, to processID: pid_t, attachAuthMessage: Bool = true) -> Bool {
        if SkyLightBridge.postToPid(processID, event: event, attachAuthMessage: attachAuthMessage) {
            return true
        }
        event.postToPid(processID)
        return true
    }

    @discardableResult
    static func focusWithoutRaise(processID: pid_t, windowID: CGWindowID?) -> Bool {
        guard let windowID, windowID > 0 else { return false }
        if let focusWithoutRaiseForTests {
            return focusWithoutRaiseForTests(processID, windowID)
        }
        return FocusWithoutRaise.activate(targetPID: processID, windowID: windowID)
    }

    @discardableResult
    static func click(
        at point: CGPoint,
        processID: pid_t,
        windowID: CGWindowID?,
        button: MouseButton = .left,
        clickCount: Int = 1,
        useOffscreenActivationPrimer: Bool = false
    ) -> Bool {
        let clampedCount = max(1, min(clickCount, 2))
        if let windowID, windowID > 0 {
            guard focusWithoutRaise(processID: processID, windowID: windowID) else {
                return false
            }
            usleep(50_000)
        }

        guard button == .left else {
            return postMousePair(
                at: point,
                windowLocalPoint: windowLocalPoint(point, windowID: windowID),
                processID: processID,
                windowID: windowID,
                type: (.rightMouseDown, .rightMouseUp),
                clickState: 1
            )
        }

        _ = postMouseMove(
            at: point,
            windowLocalPoint: windowLocalPoint(point, windowID: windowID),
            processID: processID,
            windowID: windowID
        )
        usleep(15_000)
        if useOffscreenActivationPrimer {
            // Chromium-style primer: an off-screen click can open the renderer
            // user-activation gate. Keep it opt-in so one model click maps to
            // one delivered click for generic apps.
            let offscreen = CGPoint(x: -1, y: -1)
            _ = postMousePair(
                at: offscreen,
                windowLocalPoint: offscreen,
                processID: processID,
                windowID: windowID,
                type: (.leftMouseDown, .leftMouseUp),
                clickState: 1
            )
            usleep(100_000)
        }

        var ok = true
        for index in 1...clampedCount {
            ok = postMousePair(
                at: point,
                windowLocalPoint: windowLocalPoint(point, windowID: windowID),
                processID: processID,
                windowID: windowID,
                type: (.leftMouseDown, .leftMouseUp),
                clickState: Int64(index)
            ) && ok
            if index < clampedCount {
                usleep(80_000)
            }
        }
        return ok
    }

    private static func postMouseMove(
        at point: CGPoint,
        windowLocalPoint: CGPoint,
        processID: pid_t,
        windowID: CGWindowID?
    ) -> Bool {
        guard let event = makeMouseEvent(.mouseMoved, at: point, windowID: windowID, clickCount: 0) else {
            return false
        }
        stampMouseEvent(event, point: point, windowLocalPoint: windowLocalPoint, processID: processID, windowID: windowID, clickState: 0)
        return SkyLightBridge.postToPid(processID, event: event, attachAuthMessage: false) || {
            event.postToPid(processID)
            return true
        }()
    }

    private static func postMousePair(
        at point: CGPoint,
        windowLocalPoint: CGPoint,
        processID: pid_t,
        windowID: CGWindowID?,
        type: (down: NSEvent.EventType, up: NSEvent.EventType),
        clickState: Int64
    ) -> Bool {
        guard let down = makeMouseEvent(type.down, at: point, windowID: windowID, clickCount: Int(clickState)),
              let up = makeMouseEvent(type.up, at: point, windowID: windowID, clickCount: Int(clickState))
        else { return false }
        stampMouseEvent(down, point: point, windowLocalPoint: windowLocalPoint, processID: processID, windowID: windowID, clickState: clickState)
        stampMouseEvent(up, point: point, windowLocalPoint: windowLocalPoint, processID: processID, windowID: windowID, clickState: clickState)
        let downPosted = SkyLightBridge.postToPid(processID, event: down, attachAuthMessage: false)
        if !downPosted { down.postToPid(processID) }
        usleep(1_000)
        let upPosted = SkyLightBridge.postToPid(processID, event: up, attachAuthMessage: false)
        if !upPosted { up.postToPid(processID) }
        return true
    }

    private static func makeMouseEvent(_ type: NSEvent.EventType, at point: CGPoint, windowID: CGWindowID?, clickCount: Int) -> CGEvent? {
        let cocoaPoint = cocoaLocation(fromScreenPoint: point)
        let nsEvent = NSEvent.mouseEvent(
            with: type,
            location: cocoaPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: Int(windowID ?? 0),
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        )
        return nsEvent?.cgEvent
    }

    private static func stampMouseEvent(
        _ event: CGEvent,
        point: CGPoint,
        windowLocalPoint: CGPoint,
        processID: pid_t,
        windowID: CGWindowID?,
        clickState: Int64
    ) {
        event.location = point
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        if let windowID, windowID > 0 {
            let windowValue = Int64(windowID)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowValue)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowValue)
            _ = SkyLightBridge.setWindowLocation(event, windowLocalPoint)
            _ = SkyLightBridge.setIntegerField(event, field: 51, value: windowValue)
            _ = SkyLightBridge.setIntegerField(event, field: 91, value: windowValue)
            _ = SkyLightBridge.setIntegerField(event, field: 92, value: windowValue)
        }
        _ = SkyLightBridge.setIntegerField(event, field: 40, value: Int64(processID))
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static func cocoaLocation(fromScreenPoint point: CGPoint) -> CGPoint {
        let screenHeight = NSScreen.main?.frame.height ?? 0
        return CGPoint(x: point.x, y: max(0, screenHeight - point.y))
    }

    private static func windowLocalPoint(_ point: CGPoint, windowID: CGWindowID?) -> CGPoint {
        guard let windowID,
              let bounds = windowBounds(windowID: windowID)
        else { return point }
        return CGPoint(x: point.x - bounds.origin.x, y: point.y - bounds.origin.y)
    }

    private static func windowBounds(windowID: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let infos = CGWindowListCopyWindowInfo(options, windowID) as? [[CFString: Any]],
              let info = infos.first,
              let bounds = info[kCGWindowBounds] as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}

private enum FocusWithoutRaise {
    @discardableResult
    static func activate(targetPID: pid_t, windowID: CGWindowID) -> Bool {
        guard SkyLightBridge.isFocusWithoutRaiseAvailable else { return false }

        var previousPSN = [UInt32](repeating: 0, count: 2)
        var targetPSN = [UInt32](repeating: 0, count: 2)
        let previousOK = previousPSN.withUnsafeMutableBytes { raw in
            SkyLightBridge.getFrontProcess(raw.baseAddress!)
        }
        guard previousOK else { return false }

        let targetOK = targetPSN.withUnsafeMutableBytes { raw in
            SkyLightBridge.getProcessPSN(forWindowID: windowID, into: raw.baseAddress!)
        }
        guard targetOK else { return false }

        var buffer = [UInt8](repeating: 0, count: 0xF8)
        buffer[0x04] = 0xF8
        buffer[0x08] = 0x0D
        let windowValue = UInt32(windowID)
        buffer[0x3C] = UInt8(windowValue & 0xFF)
        buffer[0x3D] = UInt8((windowValue >> 8) & 0xFF)
        buffer[0x3E] = UInt8((windowValue >> 16) & 0xFF)
        buffer[0x3F] = UInt8((windowValue >> 24) & 0xFF)

        buffer[0x8A] = 0x02
        let defocusOK = previousPSN.withUnsafeBytes { psnRaw in
            buffer.withUnsafeBufferPointer { bp in
                SkyLightBridge.postEventRecordTo(psn: psnRaw.baseAddress!, bytes: bp.baseAddress!)
            }
        }
        buffer[0x8A] = 0x01
        let focusOK = targetPSN.withUnsafeBytes { psnRaw in
            buffer.withUnsafeBufferPointer { bp in
                SkyLightBridge.postEventRecordTo(psn: psnRaw.baseAddress!, bytes: bp.baseAddress!)
            }
        }
        return defocusOK && focusOK
    }
}

private enum SkyLightBridge {
    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthMessageFn = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias FactoryMsgSendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> AnyObject?
    private typealias SetIntFieldFn = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias PostEventRecordToFn = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
    private typealias GetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetWindowOwnerFn = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias GetConnectionPSNFn = @convention(c) (UInt32, UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias MainConnectionIDFn = @convention(c) () -> UInt32

    private struct Resolved {
        let postToPid: PostToPidFn
        let setAuthMessage: SetAuthMessageFn
        let msgSendFactory: FactoryMsgSendFn
        let messageClass: AnyClass
        let factorySelector: Selector
    }

    private static let resolved: Resolved? = {
        loadSkyLight()
        guard let postToPid = symbol("SLEventPostToPid", as: PostToPidFn.self),
              let setAuth = symbol("SLEventSetAuthenticationMessage", as: SetAuthMessageFn.self),
              let msgSend = symbol("objc_msgSend", as: FactoryMsgSendFn.self),
              let messageClass = NSClassFromString("SLSEventAuthenticationMessage")
        else { return nil }
        let selector = NSSelectorFromString("messageWithEventRecord:pid:version:")
        guard messageClass.responds(to: selector) else { return nil }
        return Resolved(
            postToPid: postToPid,
            setAuthMessage: setAuth,
            msgSendFactory: msgSend,
            messageClass: messageClass,
            factorySelector: selector
        )
    }()

    private static let setIntField: SetIntFieldFn? = {
        loadSkyLight()
        return symbol("SLEventSetIntegerValueField", as: SetIntFieldFn.self)
    }()

    private static let setWindowLocationFn: SetWindowLocationFn? = {
        loadSkyLight()
        return symbol("CGEventSetWindowLocation", as: SetWindowLocationFn.self)
    }()

    private static let postEventRecordToFn: PostEventRecordToFn? = {
        loadSkyLight()
        return symbol("SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
    }()

    private static let getFrontProcessFn: GetFrontProcessFn? = {
        loadSkyLight()
        return symbol("_SLPSGetFrontProcess", as: GetFrontProcessFn.self)
    }()

    private static let getWindowOwnerFn: GetWindowOwnerFn? = {
        loadSkyLight()
        return symbol("SLSGetWindowOwner", as: GetWindowOwnerFn.self)
    }()

    private static let getConnectionPSNFn: GetConnectionPSNFn? = {
        loadSkyLight()
        return symbol("SLSGetConnectionPSN", as: GetConnectionPSNFn.self)
    }()

    private static let getProcessForPIDFn: GetProcessForPIDFn? = {
        symbol("GetProcessForPID", as: GetProcessForPIDFn.self)
    }()

    private static let mainConnectionIDFn: MainConnectionIDFn? = {
        loadSkyLight()
        return symbol("CGSMainConnectionID", as: MainConnectionIDFn.self)
    }()

    static var isFocusWithoutRaiseAvailable: Bool {
        getFrontProcessFn != nil
            && postEventRecordToFn != nil
            && ((getWindowOwnerFn != nil && getConnectionPSNFn != nil && mainConnectionIDFn != nil) || getProcessForPIDFn != nil)
    }

    @discardableResult
    static func postToPid(_ pid: pid_t, event: CGEvent, attachAuthMessage: Bool) -> Bool {
        guard let resolved else { return false }
        if attachAuthMessage,
           let record = eventRecord(from: event),
           let message = resolved.msgSendFactory(
            resolved.messageClass as AnyObject,
            resolved.factorySelector,
            record,
            pid,
            0
           ) {
            resolved.setAuthMessage(event, message)
        }
        resolved.postToPid(pid, event)
        return true
    }

    @discardableResult
    static func setIntegerField(_ event: CGEvent, field: UInt32, value: Int64) -> Bool {
        guard let setIntField else { return false }
        setIntField(event, field, value)
        return true
    }

    @discardableResult
    static func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        guard let setWindowLocationFn else { return false }
        setWindowLocationFn(event, point)
        return true
    }

    static func getFrontProcess(_ psnBuffer: UnsafeMutableRawPointer) -> Bool {
        guard let getFrontProcessFn else { return false }
        return getFrontProcessFn(psnBuffer) == 0
    }

    static func getProcessPSN(forPID pid: pid_t, into psnBuffer: UnsafeMutableRawPointer) -> Bool {
        guard let getProcessForPIDFn else { return false }
        return getProcessForPIDFn(pid, psnBuffer) == 0
    }

    static func getProcessPSN(forWindowID windowID: CGWindowID, into psnBuffer: UnsafeMutableRawPointer) -> Bool {
        guard let getWindowOwnerFn,
              let getConnectionPSNFn,
              let mainConnectionIDFn
        else { return false }
        var ownerConnectionID: UInt32 = 0
        guard getWindowOwnerFn(mainConnectionIDFn(), UInt32(windowID), &ownerConnectionID) == 0 else {
            return false
        }
        return getConnectionPSNFn(ownerConnectionID, psnBuffer) == 0
    }

    @discardableResult
    static func postEventRecordTo(psn: UnsafeRawPointer, bytes: UnsafePointer<UInt8>) -> Bool {
        guard let postEventRecordToFn else { return false }
        return postEventRecordToFn(psn, bytes) == 0
    }

    private static func eventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let pointer = slot.pointee {
                return pointer
            }
        }
        return nil
    }

    private static func loadSkyLight() {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}
