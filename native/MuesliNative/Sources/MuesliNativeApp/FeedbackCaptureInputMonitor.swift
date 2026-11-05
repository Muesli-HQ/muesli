import AppKit
import AVFoundation
import Carbon
import MuesliCore

/// File operations and periodic durability stay off the event/UI thread.
private final class FeedbackCaptureEventJournal: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.muesli.feedback-events", qos: .utility)
    private let url: URL
    private let report: @Sendable (String) -> Void
    private var handle: FileHandle?
    private var timer: DispatchSourceTimer?
    private var failures: [String] = []
    private var stopped = false
    init(url: URL, report: @escaping @Sendable (String) -> Void) { self.url = url; self.report = report }
    deinit { timer?.cancel(); try? handle?.close() }
    private func failed(_ error: Error) {
        let message = error.localizedDescription
        if !failures.contains(message) { failures.append(message); report(message) }
    }
    func append(_ event: FeedbackCaptureJournalRecord) {
        queue.async { [self] in
            guard !stopped else { return }
            do {
                if handle == nil {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                            throw ScreenVideoRecorder.error("Cannot create event journal")
                        }
                    }
                    handle = try FileHandle(forWritingTo: url); try handle?.seekToEnd()
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + 1, repeating: 1)
                    timer.setEventHandler { [weak self] in self?.flush() }
                    self.timer = timer; timer.resume()
                }
                var record = try JSONEncoder().encode(event); record.append(10)
                try handle?.write(contentsOf: record)
            } catch { failed(error) }
        }
    }
    private func flush() {
        do { try handle?.synchronize() } catch { failed(error) }
    }
    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true; timer?.cancel(); timer = nil
            flush()
            do { try handle?.close() } catch { failed(error) }
            handle = nil
        }
    }
    func drain() async -> [String] {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.failures) } }
    }
}

@MainActor
final class FeedbackCaptureInputMonitor {
    private var input: FeedbackCaptureEvents
    private var ink: FeedbackCaptureInk
    private let target: FeedbackCaptureTarget
    private let origin: () -> Int64?
    private let admitted: () -> Bool
    private let onFailure: (String) -> Void
    private let onGap: (FeedbackCaptureInputGap) -> Void
    private let currentPressedMouseButtons: () -> Set<Int>
    private var journal: FeedbackCaptureEventJournal!
    private var monitor: Any?
    private var undoMonitor: Any?
    private var timer: Timer?
    private var overlay: FeedbackCaptureInkOverlay?
    private var retired = false
    private var gapStart: Int64?
    private var monitorUnavailable = false
    private var ordinaryButtons: Set<Int> = []
    private var inkButtons: Set<Int> = []
    private var reported: Set<String> = []
    init(target: FeedbackCaptureTarget, url: URL, origin: @escaping () -> Int64?, admitted: @escaping () -> Bool,
         onFailure: @escaping (String) -> Void, onGap: @escaping (FeedbackCaptureInputGap) -> Void = { _ in },
         currentPressedMouseButtons: @escaping () -> Set<Int> = {
            let buttons = NSEvent.pressedMouseButtons
            return Set((0..<UInt.bitWidth).filter { buttons & (1 << $0) != 0 })
         },
         modifier: FeedbackCaptureDrawModifier = .shift) {
        self.target = target; input = FeedbackCaptureEvents(target: target)
        ink = FeedbackCaptureInk(target: target, modifier: modifier)
        self.origin = origin; self.admitted = admitted; self.onFailure = onFailure; self.onGap = onGap
        self.currentPressedMouseButtons = currentPressedMouseButtons
        journal = FeedbackCaptureEventJournal(url: url) { [weak self] message in
            Task { @MainActor in self?.report(message) }
        }
    }
    private func report(_ message: String) {
        if reported.insert(message).inserted { onFailure(message) }
    }
    static func quartzPoint(cocoa: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
    }
    struct WindowSnapshot {
        let ownerPID: Int32
        let windowNumber: Int
        let bounds: CGRect
        let alpha: CGFloat
    }
    struct InteractiveWindowSnapshot {
        let windowNumber: Int
        let frame: CGRect
    }
    @MainActor struct WindowStackSnapshotCache {
        private struct Snapshot {
            let refreshedAt: TimeInterval
            let windowStack: [WindowSnapshot]?
        }
        private static let refreshInterval: TimeInterval = 0.2
        private var snapshot: Snapshot?

        mutating func isExcluded(_ cocoa: CGPoint, primaryHeight: CGFloat, processIdentifier: Int32,
                                 interactiveWindows: [InteractiveWindowSnapshot], now: TimeInterval,
                                 refresh: () -> [WindowSnapshot]?) -> Bool {
            guard interactiveWindows.contains(where: { $0.frame.contains(cocoa) }) else { return false }
            let windowStack: [WindowSnapshot]?
            if let snapshot, now >= snapshot.refreshedAt,
               now - snapshot.refreshedAt < Self.refreshInterval {
                windowStack = snapshot.windowStack
            } else {
                let refreshedWindowStack = refresh()
                snapshot = Snapshot(refreshedAt: now, windowStack: refreshedWindowStack)
                windowStack = refreshedWindowStack
            }
            guard let windowStack else { return true }
            return FeedbackCaptureInputMonitor.isExcluded(cocoa, primaryHeight: primaryHeight,
                processIdentifier: processIdentifier,
                interactiveOwnWindowIDs: Set(interactiveWindows.map(\.windowNumber)), windowStack: windowStack)
        }
    }
    static func isExcluded(_ cocoa: CGPoint, primaryHeight: CGFloat, processIdentifier: Int32,
                           interactiveOwnWindowIDs: Set<Int>, windowStack: [WindowSnapshot]) -> Bool {
        let point = quartzPoint(cocoa: cocoa, primaryHeight: primaryHeight)
        for window in windowStack where window.alpha > 0 && window.bounds.contains(point) {
            guard window.ownerPID == processIdentifier else { return false }
            if interactiveOwnWindowIDs.contains(window.windowNumber) { return true }
        }
        return false
    }
    private static func modifiers() -> Set<FeedbackCaptureInk.Modifier> {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var result: Set<FeedbackCaptureInk.Modifier> = []
        for (flag, modifier): (CGEventFlags, FeedbackCaptureInk.Modifier) in [
            (.maskShift, .shift), (.maskAlternate, .option), (.maskControl, .control),
            (.maskSecondaryFn, .fn), (.maskCommand, .command)
        ] where flags.contains(flag) { result.insert(modifier) }
        return result
    }
    private static func eventModifiers(_ flags: NSEvent.ModifierFlags) -> Set<FeedbackCaptureInk.Modifier> {
        var result: Set<FeedbackCaptureInk.Modifier> = []
        for (flag, modifier): (NSEvent.ModifierFlags, FeedbackCaptureInk.Modifier) in [
            (.shift, .shift), (.option, .option), (.control, .control),
            (.function, .fn), (.command, .command)
        ] where flags.contains(flag) { result.insert(modifier) }
        return result
    }
    private static func interactiveWindows() -> [InteractiveWindowSnapshot] {
        NSApp.windows.compactMap { window in
            guard window.isVisible, !window.ignoresMouseEvents, window.alphaValue > 0 else { return nil }
            return .init(windowNumber: window.windowNumber, frame: window.frame)
        }
    }
    private static func windowStack() -> [WindowSnapshot]? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return info.compactMap { item -> WindowSnapshot? in
            guard let ownerPID = item[kCGWindowOwnerPID as String] as? Int32,
                  let windowNumber = item[kCGWindowNumber as String] as? Int,
                  let boundsDictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  let alpha = item[kCGWindowAlpha as String] as? CGFloat else { return nil }
            return .init(ownerPID: ownerPID, windowNumber: windowNumber, bounds: bounds, alpha: alpha)
        }
    }
    private var windowStackCache = WindowStackSnapshotCache()
    private func excluded(_ cocoa: CGPoint) -> Bool {
        windowStackCache.isExcluded(cocoa, primaryHeight: NSScreen.screens.first?.frame.maxY ?? 0,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            interactiveWindows: Self.interactiveWindows(), now: ProcessInfo.processInfo.systemUptime) {
                Self.windowStack()
            }
    }
    func receiveMouseEvent(_ event: NSEvent) {
        guard let point = event.cgEvent?.location else { return }
        let phase: FeedbackCaptureEvents.Phase
        switch event.type {
        case .leftMouseDown, .rightMouseDown: phase = .down
        case .leftMouseUp, .rightMouseUp: phase = .up
        case .leftMouseDragged, .rightMouseDragged: phase = .moved
        case .scrollWheel: phase = .scroll
        default: return
        }
        receive(phase, eventTimestamp: event.timestamp, x: point.x, y: point.y,
            button: event.buttonNumber,
            dx: phase == .scroll ? Double(event.scrollingDeltaX) : 0,
            dy: phase == .scroll ? Double(event.scrollingDeltaY) : 0,
            modifiers: Self.eventModifiers(event.modifierFlags))
    }
    func start() {
        guard !retired, timer == nil, admitted() else { return }
        // Global monitors are passive and exclude events delivered to our app.
        // Do not infer event ownership from visible-window geometry: another app may cover us.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.receiveMouseEvent(event)
            }
        }
        // Observe only the physical Z key with Command alone. Never read characters.
        undoMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard event.keyCode == 6,
                      event.modifierFlags.intersection([.command, .control, .option, .shift, .function]) == .command else { return }
                guard !IsSecureEventInputEnabled() else { return }
                self?.undo(frame: MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()))
            }
        }
        monitorUnavailable = monitor == nil || undoMonitor == nil
        if monitor == nil { report("Global pointer monitoring unavailable") }
        if undoMonitor == nil { report("Passive undo monitoring unavailable") }
        overlay = FeedbackCaptureInkOverlay(target: target)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        poll()
    }
    private func poll() {
        let cocoa = NSEvent.mouseLocation
        let point = Self.quartzPoint(cocoa: cocoa, primaryHeight: NSScreen.screens.first?.frame.maxY ?? 0)
        sample(frame: MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time()), x: point.x, y: point.y,
               modifiers: Self.modifiers(), secureInput: IsSecureEventInputEnabled(), excluded: excluded(cocoa))
    }
    private func relative(_ frame: Int64) -> Int64? {
        guard let origin = origin(), frame >= origin else { return nil }
        return FeedbackCaptureManifest.milliseconds(frame: frame, origin: origin)
    }
    // The global monitor excludes events delivered to Muesli. A visible window may sit behind
    // another app, so geometry alone must not suppress this globally monitored input.
    func receive(_ phase: FeedbackCaptureEvents.Phase, eventTimestamp: TimeInterval, x: Double, y: Double,
                 button: Int = 0, dx: Double = 0, dy: Double = 0, excluded _: Bool = false,
                 modifiers: Set<FeedbackCaptureInk.Modifier> = []) {
        guard eventTimestamp.isFinite, eventTimestamp >= 0 else { return }
        let frame = MicrophoneCaptureAudio.frame(atHostTime: AVAudioTime.hostTime(forSeconds: eventTimestamp))
        receive(phase, frame: frame, x: x, y: y, button: button, dx: dx, dy: dy,
                modifiers: modifiers)
    }
    private func gap(unavailable: Bool, t: Int64) {
        if unavailable, gapStart == nil { gapStart = t; journal.append(.gap(t: t, unavailable: true)) }
        else if !unavailable, let start = gapStart {
            gapStart = nil; journal.append(.gap(t: t, unavailable: false))
            onGap(.init(t0: start, t1: max(start, t)))
        }
    }
    func sample(frame: Int64, x: Double, y: Double, modifiers: Set<FeedbackCaptureInk.Modifier>, secureInput: Bool, excluded: Bool = false) {
        guard !retired, admitted(), let time = relative(frame) else { return }
        gap(unavailable: secureInput || monitorUnavailable, t: time)
        // Global monitors miss local starts; classify held buttons unless captured ink owns them.
        let pressedButtons = currentPressedMouseButtons()
        ordinaryButtons.formIntersection(pressedButtons)
        inkButtons.formIntersection(pressedButtons)
        ordinaryButtons.formUnion(pressedButtons.subtracting(inkButtons))
        // A press already classified as ordinary stays ordinary through its release.
        if let stroke = ink.sample(t: time, x: x, y: y, modifiers: ordinaryButtons.isEmpty ? modifiers : [], excluded: excluded) { journal.append(.stroke(stroke)) }
        overlay?.update(strokes: ink.strokes, live: ink.visibleLiveStroke, t: time)
    }
    func receive(_ phase: FeedbackCaptureEvents.Phase, frame: Int64, x: Double, y: Double,
                 button: Int = 0, dx: Double = 0, dy: Double = 0, excluded _: Bool = false,
                 modifiers: Set<FeedbackCaptureInk.Modifier> = []) {
        guard !retired, admitted(), let time = relative(frame) else { return }
        // A confirmed global mouse-down disambiguates a press that polling saw first.
        if phase == .down { ordinaryButtons.remove(button) }
        if phase != .scroll, !ordinaryButtons.contains(button) {
            let result = ink.pointer(phase, t: time, x: x, y: y, modifiers: modifiers, button: button)
            if let stroke = result.stroke { journal.append(.stroke(stroke)) }
            if result.owned {
                if phase == .down { inkButtons.insert(button) }
                if phase == .up { inkButtons.remove(button) }
                overlay?.update(strokes: ink.strokes, live: ink.visibleLiveStroke, t: time); return
            }
        }
        if phase == .down { ordinaryButtons.insert(button) }
        if phase == .up { ordinaryButtons.remove(button) }
        if let event = input.receive(phase, t: time, x: x, y: y, button: button, dx: dx, dy: dy) {
            journal.append(.pointer(event))
        }
    }
    func undo(frame: Int64) {
        guard !retired, admitted(), gapStart == nil, let time = relative(frame) else { return }
        if let stroke = ink.finish(t: time) { journal.append(.stroke(stroke)) }
        guard let stroke = ink.strokes.last else { return }
        ink.undo(); journal.append(.undo(time, stroke: stroke))
        overlay?.update(strokes: ink.strokes, live: ink.visibleLiveStroke, t: time)
    }
    func stop(frame: Int64 = MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time())) {
        guard !retired else { return }
        if let time = relative(frame) {
            if let stroke = ink.finish(t: time) { journal.append(.stroke(stroke)) }
            gap(unavailable: false, t: time)
        }
        retired = true
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let undoMonitor { NSEvent.removeMonitor(undoMonitor); self.undoMonitor = nil }
        overlay?.stop(); overlay = nil
        journal.stop()
    }
    func drain() async {
        for message in await journal.drain() { report(message) }
    }
}
