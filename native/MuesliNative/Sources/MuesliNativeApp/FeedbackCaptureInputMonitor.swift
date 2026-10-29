import AppKit
import AVFoundation
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
    func append(_ event: FeedbackCaptureEvent) {
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
    private let origin: () -> Int64?
    private let admitted: () -> Bool
    private let onFailure: (String) -> Void
    private let onGap: (FeedbackCaptureInputGap) -> Void
    private var journal: FeedbackCaptureEventJournal!
    private var monitor: Any?
    private var retired = false
    private var gapStart: Int64?
    private var reported: Set<String> = []
    init(target: FeedbackCaptureTarget, url: URL, origin: @escaping () -> Int64?, admitted: @escaping () -> Bool,
         onFailure: @escaping (String) -> Void, onGap: @escaping (FeedbackCaptureInputGap) -> Void = { _ in }) {
        input = FeedbackCaptureEvents(target: target)
        self.origin = origin; self.admitted = admitted; self.onFailure = onFailure; self.onGap = onGap
        journal = FeedbackCaptureEventJournal(url: url) { [weak self] message in
            Task { @MainActor in self?.report(message) }
        }
    }
    private func report(_ message: String) {
        if reported.insert(message).inserted { onFailure(message) }
    }
    func start() {
        guard !retired, monitor == nil, admitted() else { return }
        // A global monitor is passive and excludes events delivered to our app.
        // Do not infer event ownership from visible-window geometry: another app may cover us.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let point = event.cgEvent?.location else { return }
                let phase: FeedbackCaptureEvents.Phase
                switch event.type {
                case .leftMouseDown, .rightMouseDown: phase = .down
                case .leftMouseUp, .rightMouseUp: phase = .up
                case .leftMouseDragged, .rightMouseDragged: phase = .moved
                case .scrollWheel: phase = .scroll
                default: return
                }
                self.receive(phase, eventTimestamp: event.timestamp,
                    x: point.x, y: point.y, button: event.buttonNumber,
                    dx: phase == .scroll ? Double(event.scrollingDeltaX) : 0,
                    dy: phase == .scroll ? Double(event.scrollingDeltaY) : 0)
            }
        }
        if monitor == nil {
            gapStart = relative(MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time())) ?? 0
            report("Global pointer monitoring unavailable")
        }
    }
    private func relative(_ frame: Int64) -> Int64? {
        guard let origin = origin(), frame >= origin else { return nil }
        return FeedbackCaptureManifest.milliseconds(frame: frame, origin: origin)
    }
    // `excluded` is a legacy geometry hint; the global monitor already excludes events delivered to Muesli.
    func receive(_ phase: FeedbackCaptureEvents.Phase, eventTimestamp: TimeInterval, x: Double, y: Double,
                 button: Int = 0, dx: Double = 0, dy: Double = 0, excluded _: Bool = false) {
        guard eventTimestamp.isFinite, eventTimestamp >= 0 else { return }
        let frame = MicrophoneCaptureAudio.frame(atHostTime: AVAudioTime.hostTime(forSeconds: eventTimestamp))
        receive(phase, frame: frame, x: x, y: y, button: button, dx: dx, dy: dy)
    }
    func receive(_ phase: FeedbackCaptureEvents.Phase, frame: Int64, x: Double, y: Double,
                 button: Int = 0, dx: Double = 0, dy: Double = 0, excluded _: Bool = false) {
        guard !retired, admitted(), let time = relative(frame) else { return }
        if let event = input.receive(phase, t: time, x: x, y: y, button: button, dx: dx, dy: dy) {
            journal.append(event)
        }
    }
    func stop() {
        guard !retired else { return }
        retired = true
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let start = gapStart {
            let end = relative(MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time())) ?? start
            onGap(.init(t0: start, t1: max(start, end)))
        }
        journal.stop()
    }
    func drain() async {
        for message in await journal.drain() { report(message) }
    }
}
