import AppKit
import AVFoundation
import CoreAudio
import MuesliCore
import Observation
import ScreenCaptureKit

struct FeedbackCaptureAdmission {
    static func missingPermission(_ snapshot: InteractionPermissionSnapshot) -> String? {
        if !snapshot.screenRecording { return "Screen Recording" }
        if !snapshot.microphone { return "Microphone" }
        if !snapshot.accessibility { return "Accessibility" }
        if !snapshot.inputMonitoring { return "Input Monitoring" }
        return nil
    }
    static func mustFinish(start: Date, now: Date, original: FeedbackCaptureTarget,
                           current: FeedbackCaptureTarget?) -> Bool {
        now.timeIntervalSince(start) >= 600 || current?.displayId != original.displayId || current?.frame != original.frame
    }
}

/// One attempt owns its devices, files and clock journal through actual writer completion.
/// Native microphone commands share a queue, so cancellation cannot race a late start.
final class FeedbackCaptureAttempt: @unchecked Sendable {
    enum Phase { case preparing, recording, stopping }
    private var phase = Phase.preparing
    private var resourcesInstalled = false
    let target: FeedbackCaptureTarget
    let admittedAt: Date
    private var recordingStart: Date?
    let queue = DispatchQueue(label: "com.muesli.feedback-microphone", qos: .userInitiated)
    private let lock = NSRecursiveLock()
    private(set) var microphone: (any StreamingDictationRecording & MicrophoneCaptureReporting)?
    private var drainEndFrame: Int64?
    private var manifest: FeedbackCaptureManifest?
    private var writer: MeetingRecordingWriter?
    private(set) var video: ScreenVideoRecorder?
    private var lastSample: Date?
    private var power: Float = -160
    let store: FeedbackCaptureStore
    var onFailure: (@Sendable (String) -> Void)?

    init(target: FeedbackCaptureTarget, store: FeedbackCaptureStore, now: Date = Date()) {
        self.target = target; self.store = store; admittedAt = now
    }
    var isCurrent: Bool { lock.withLock { phase != .stopping } }
    var hasResources: Bool { lock.withLock { resourcesInstalled } }
    var startedAt: Date? { lock.withLock { recordingStart } }
    func didStart(at now: Date) {
        lock.withLock { if phase == .preparing { phase = .recording; recordingStart = now } }
    }
    static func temporaryDirectoryNames(identity: String = AppIdentity.supportDirectoryName) -> [String] {
        ["muesli-feedback-mic-" + identity, "muesli-feedback-mic-fallback-" + identity]
    }
    func prepareResources(device: AudioObjectID?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.install(device: device); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// Close fresh admission immediately, but retain captured input through Finish
    /// until the microphone has drained its native and processing queues.
    func finishAdmission(through frame: Int64 = MicrophoneCaptureAudio.frame(atHostTime: mach_absolute_time())) {
        let recorder = lock.withLock {
            phase = .stopping; drainEndFrame = frame
            return video
        }
        recorder?.requestStop(at: CMTime(value: frame, timescale: 16_000))
    }
    private var stopDrainRange: Range<Int64>? {
        lock.withLock { drainEndFrame.map { 0..<max(0, $0) } }
    }
    func snapshot() -> FeedbackCaptureManifest? { lock.withLock { manifest } }
    func meter(now: Date) -> (Bool, Float) {
        lock.withLock { (FeedbackCapturePillState.microphoneIsDead(lastSample: lastSample, startedAt: recordingStart ?? admittedAt, now: now), power) }
    }
    /// Production installation runs on the device queue, after discovery admission.
    func install(device: AudioObjectID?, microphone suppliedMicrophone: (any StreamingDictationRecording & MicrophoneCaptureReporting)? = nil) throws {
        try lock.withLock {
            guard phase == .preparing, !resourcesInstalled else { throw CancellationError() }
            resourcesInstalled = true
        }
        let created = try store.begin(target: target)
        lock.withLock { manifest = created }
        let writer = try MeetingRecordingWriter(destination: store.mediaURL(id: created.id, path: "narration.wav"))
        lock.withLock { self.writer = writer }
        let video = ScreenVideoRecorder(url: try store.mediaURL(id: created.id, path: "recording.mp4"), feedbackCapture: true)
        lock.withLock { self.video = video }
        video.onFirstVideoFrame = { [weak self] frame in self?.videoBegan(frame) }
        video.onFailure = { [weak self] message in self?.onFailure?(message) }
        let mic: any StreamingDictationRecording & MicrophoneCaptureReporting = suppliedMicrophone ?? FallbackStreamingDictationRecorder(
            primary: AudioQueueInputRecorder(directoryName: Self.temporaryDirectoryNames()[0]),
            fallback: StreamingMicRecorder(directoryName: Self.temporaryDirectoryNames()[1],
                recoversFromInputConfigurationChanges: false, observesInputConfigurationChanges: false))
        mic.preferredInputDeviceID = device
        mic.shouldAdmitSamples = { [weak self] in self?.isCurrent == true }
        mic.nativeStopDrainRange = { [weak self] in self?.stopDrainRange }
        mic.onCapturedAudio = { [weak self] block in self?.receive(block) }
        mic.onRecordingFailed = { [weak self] error in self?.onFailure?(error.localizedDescription) }
        lock.withLock { microphone = mic }
        if !isCurrent, let cutoff = lock.withLock({ drainEndFrame }) {
            video.requestStop(at: CMTime(value: cutoff, timescale: 16_000))
        }
    }
    func startMicrophone() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard isCurrent, let microphone else { throw CancellationError() }
                    try microphone.prepare()
                    guard isCurrent else { throw CancellationError() }
                    try microphone.start()
                    guard isCurrent else { throw CancellationError() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stopMicrophone() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let microphone = microphone
                if let url = microphone?.stop() { try? FileManager.default.removeItem(at: url) }
                microphone?.cancel()
                lock.withLock { drainEndFrame = nil }
                continuation.resume()
            }
        }
    }
    private func checkpointClocks() {
        queue.async { [self] in
            guard let manifest = snapshot() else { return }
            do { try store.checkpoint(manifest) }
            catch { addFailure(stage: "journal", message: error.localizedDescription); onFailure?(error.localizedDescription) }
        }
    }
    func drainJournal() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    private func videoBegan(_ frame: Int64) {
        lock.withLock { manifest?.videoStartFrame = frame; manifest?.alignClocks() }
        checkpointClocks()
    }
    func receive(_ incoming: MicrophoneCaptureAudio, now: Date = Date()) {
        guard incoming.admitted, !incoming.samples.isEmpty else { return }
        let admitted = lock.withLock { () -> (MicrophoneCaptureAudio, Bool)? in
            guard manifest != nil else { return nil }
            var block = incoming
            if phase == .stopping {
                guard let end = drainEndFrame, block.startFrame < end else { return nil }
                block.samples = Array(block.samples.prefix(Int(min(Int64(block.samples.count), end - block.startFrame))))
            }
            let first = manifest?.microphoneStartFrame == nil
            if first { manifest?.microphoneStartFrame = block.startFrame; manifest?.alignClocks() }
            return (block, first)
        }
        guard let (block, first) = admitted else { return }
        if first { checkpointClocks() }
        // Device callbacks drain before stop returns. Never hold the admission
        // lock across file I/O: Finish must establish its cutoff synchronously.
        do {
            try writer?.appendMicrophone(block.samples, startFrame: block.startFrame)
            video?.appendAudio(block.samples, microphone: true, startFrame: block.startFrame)
            let peak = block.samples.reduce(Float(0)) { max($0, abs(Float($1)) / 32768) }
            lock.withLock {
                lastSample = now; power = peak > 0 ? 20 * log10(peak) : -160
                let duration = max(manifest!.durationMs,
                    FeedbackCaptureManifest.milliseconds(frame: block.endFrame, origin: manifest!.microphoneStartFrame!))
                manifest?.durationMs = duration
            }
        } catch { onFailure?(error.localizedDescription) }
    }
    func finishAudio() {
        do {
            let hasAudio = try writer?.finishMicrophone() != nil
            if hasAudio { lock.withLock { manifest?.audio = "narration.wav" } }
            else { addFailure(stage: "audio", message: "No microphone samples were captured.") }
        } catch { addFailure(stage: "audio", message: error.localizedDescription) }
    }
    func finishVideo() async {
        guard let video else { return }
        let result: Result<Double, Error> = await withCheckedContinuation { continuation in
            video.onFinalizationResult = { result in continuation.resume(returning: result) }
            // The UI timeout must not retire the attempt's journal or release its files.
            Task { _ = try? await video.stop() }
        }
        lock.withLock {
            switch result {
            case .success(let seconds):
                manifest?.video = "recording.mp4"
                let duration = max(manifest!.durationMs, Int64(seconds * 1000) + (manifest?.videoOffsetMs ?? 0))
                manifest?.durationMs = duration
            case .failure(let error): manifest?.failures.append(.init(stage: "video", message: error.localizedDescription))
            }
        }
    }
    func addFailure(stage: String, message: String) {
        lock.withLock { manifest?.failures.append(.init(stage: stage, message: message)) }
    }
}

@MainActor @Observable
final class FeedbackCaptureController {
    private(set) var state: FeedbackCapturePillState?
    private(set) var ownsMicrophone = false
    private(set) var records: [FeedbackCaptureRecord] = []
    private(set) var errorMessage: String?
    private(set) var latestID: String?
    let store: FeedbackCaptureStore?
    var finalizer = FeedbackCaptureFinalizer()
    var onStateChanged: ((FeedbackCapturePillState?) -> Void)?
    var onMicrophoneReleased: (() -> Void)?
    var onAdmissionReset: (() -> Void)?
    private var attempt: FeedbackCaptureAttempt?
    private var startTask: Task<Void, Never>?
    private var startupDeadline: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var catalogRequestID: UInt64 = 0
    @ObservationIgnored nonisolated(unsafe) private var timer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var windowController: FeedbackCaptureWindowController?
    private let pointerTarget: @MainActor () -> FeedbackCaptureTarget?
    private let currentDisplayTarget: @MainActor (FeedbackCaptureTarget) -> FeedbackCaptureTarget?
    private let prepareScreen: (@MainActor (FeedbackCaptureAttempt, AudioObjectID?) async throws -> Void)?
    private let startupTimeout: Duration
    private let waiterTimeout: Duration
    private(set) var presentationID: UInt64 = 0
    private(set) var presentedCaptureID: String?
    private let dismissalDelay: Duration
    private let openCapture: (@MainActor (String?) -> Void)?
    private let now: () -> Date
    private let repairAudio: @Sendable (URL) throws -> Int64?
    var hasAttempt: Bool { attempt != nil }
    var admittedAt: Date? { attempt.flatMap { $0.isCurrent ? $0.admittedAt : nil } }

    init(databaseURL: URL, supportDirectory: URL,
         pointerTarget: @escaping @MainActor () -> FeedbackCaptureTarget? = FeedbackCaptureController.pointerDisplayTarget,
         currentDisplayTarget: @escaping @MainActor (FeedbackCaptureTarget) -> FeedbackCaptureTarget? = FeedbackCaptureController.displayTarget,
         prepareScreen: (@MainActor (FeedbackCaptureAttempt, AudioObjectID?) async throws -> Void)? = nil,
         startupTimeout: Duration = .seconds(8), now: @escaping () -> Date = Date.init,
         observeSystem: Bool = true, dismissalDelay: Duration = .seconds(25),
         openCapture: (@MainActor (String?) -> Void)? = nil, waiterTimeout: Duration = .seconds(8),
         repairAudio: @escaping @Sendable (URL) throws -> Int64? = { try WavWriter.repairIncrementalWAV(at: $0) }) {
        self.repairAudio = repairAudio
        self.waiterTimeout = waiterTimeout
        self.dismissalDelay = dismissalDelay; self.openCapture = openCapture
        self.pointerTarget = pointerTarget; self.currentDisplayTarget = currentDisplayTarget
        self.prepareScreen = prepareScreen; self.startupTimeout = startupTimeout; self.now = now
        do { store = try FeedbackCaptureStore(databaseURL: databaseURL, support: supportDirectory) }
        catch { store = nil; errorMessage = error.localizedDescription }
        guard observeSystem else { return }
        let stop: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: stop))
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: stop))
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkLifetime() }
        })
    }
    deinit {
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
    private var recoveryTask: Task<Void, Never>?
    func recover() async {
        if let recoveryTask { await recoveryTask.value; return }
        recoveryTask = Task { await resumeInterruptedCaptures() }
        await recoveryTask?.value
        recoveryTask = nil
    }
    private func resumeInterruptedCaptures() async {
        guard let store else { return }
        var presentation = presentationID
        do {
            let (pending, recoveryErrors) = try await Task.detached(priority: .utility) {
                var errors: [String] = []
                let pending = try store.recover(audioDuration: WavWriter.repairIncrementalWAV, videoDuration: Self.videoDuration) {
                    errors.append("\($0): \($1.localizedDescription)")
                }
                return (pending, errors)
            }.value
            var errors = recoveryErrors
            if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }
            await reload()
            for manifest in pending {
                do {
                    _ = try await finalizer.finish(manifest,
                        context: .init(store: store, finishPasteboardChangeCount: NSPasteboard.general.changeCount), completionState: .recovered)
                    if attempt == nil, presentationID == presentation {
                        latestID = manifest.id; present(.recovered, captureID: manifest.id)
                        presentation = presentationID
                    }
                } catch {
                    errors.append("\(manifest.id): \(error.localizedDescription)")
                    errorMessage = errors.joined(separator: "\n")
                }
                await Task.detached { store.release(id: manifest.id) }.value
                await reload()
            }
        } catch { errorMessage = error.localizedDescription }
    }
    nonisolated static func videoDuration(_ url: URL) throws -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return VisualMemoryController.recoverableDuration(url).map { Int64($0 * 1000) }
    }
    static func target(screen: NSScreen, appName: String) -> FeedbackCaptureTarget? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let frame = CGDisplayBounds(number.uint32Value)
        return .init(displayId: number.uint32Value,
            frame: .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height, scale: screen.backingScaleFactor), appName: appName)
    }
    static func pointerDisplayTarget() -> FeedbackCaptureTarget? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) else { return nil }
        return target(screen: screen, appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "Screen")
    }
    static func displayTarget(_ original: FeedbackCaptureTarget) -> FeedbackCaptureTarget? {
        NSScreen.screens.compactMap { target(screen: $0, appName: original.appName) }.first { $0.displayId == original.displayId }
    }
    func start(permissions: InteractionPermissionSnapshot, busyActivity: String?, device: @escaping () -> AudioObjectID?) -> Bool {
        if let permission = FeedbackCaptureAdmission.missingPermission(permissions) {
            present(.blocked(permission: permission)); return false
        }
        guard attempt == nil else {
            if !ownsMicrophone { onStateChanged?(.busy(activity: "Wait for feedback processing")) }
            return false
        }
        if let busyActivity { present(.busy(activity: busyActivity)); return false }
        guard let store, let target = pointerTarget() else {
            present(.failed(stage: "Preparation", message: errorMessage ?? "Display unavailable", retainedMedia: false)); return false
        }
        let capture = FeedbackCaptureAttempt(target: target, store: store, now: now())
        errorMessage = nil
        attempt = capture; ownsMicrophone = true; present(.preparing)
        capture.onFailure = { [weak self, weak capture] message in
            Task { @MainActor in
                guard let self, let capture, self.attempt === capture, capture.isCurrent else { return }
                capture.addFailure(stage: "recording", message: message); self.finish()
            }
        }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let prepareScreen = self.prepareScreen {
                    try await prepareScreen(capture, device())
                } else {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard self.attempt === capture, capture.isCurrent else { return }
                    guard let display = content.displays.first(where: { $0.displayID == target.displayId }),
                          let ownApp = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
                        throw ScreenVideoRecorder.error("Cannot exclude Muesli from this display")
                    }
                    guard self.currentTarget(capture) == target else { throw ScreenVideoRecorder.error("Display geometry changed") }
                    try await capture.prepareResources(device: device())
                    guard capture.isCurrent else { return }
                    let filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
                    try await capture.video!.start(filter: filter, width: display.width, height: display.height)
                }
                guard self.attempt === capture, capture.isCurrent else { return }
                try await capture.startMicrophone()
                guard self.attempt === capture, capture.isCurrent else { return }
                capture.didStart(at: self.now()); self.startupDeadline?.cancel()
                self.present(.recording(seconds: 0, deadMicrophone: false))
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkLifetime() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
                // Native startup is complete; catalog I/O must not delay teardown.
                self.startTask = nil
                await self.reload()
            } catch {
                guard self.attempt === capture, capture.isCurrent else { return }
                capture.addFailure(stage: "preparation", message: error.localizedDescription)
                self.errorMessage = error.localizedDescription
                self.finish()
            }
        }
        startupDeadline = Task { [weak self] in
            try? await Task.sleep(for: self?.startupTimeout ?? .seconds(8))
            guard !Task.isCancelled, let self, self.attempt === capture, capture.isCurrent else { return }
            capture.addFailure(stage: "preparation", message: "Startup timed out")
            self.errorMessage = "Startup timed out"; self.finish()
            let id = capture.snapshot()?.id
            self.present(.failed(stage: "Preparation", message: "Startup timed out", retainedMedia: id != nil), captureID: id)
        }
        return true
    }
    private func currentTarget(_ capture: FeedbackCaptureAttempt) -> FeedbackCaptureTarget? {
        currentDisplayTarget(capture.target)
    }
    func checkLifetime() {
        guard let capture = attempt, capture.isCurrent else { return }
        let now = now()
        let start = capture.startedAt ?? now
        if FeedbackCaptureAdmission.mustFinish(start: start, now: now, original: capture.target, current: currentTarget(capture)) { finish(); return }
        guard state?.isRecording == true else { return }
        let seconds = Int(now.timeIntervalSince(start))
        let dead = capture.meter(now: now).0
        let next: FeedbackCapturePillState
        if case .discardConfirmation = state { next = .discardConfirmation(seconds: seconds, deadMicrophone: dead) }
        else { next = .recording(seconds: seconds, deadMicrophone: dead) }
        guard next != state else { return }
        present(next)
    }
    func discard() {
        guard state?.isRecording == true else { return }
        if case .discardConfirmation = state { finish(discard: true) }
        else { present(.discardConfirmation(seconds: 0, deadMicrophone: attempt?.meter(now: Date()).0 ?? true)) }
    }
    func finish(discard: Bool = false) {
        guard let capture = attempt, capture.isCurrent else { return }
        let changeCount = NSPasteboard.general.changeCount
        capture.finishAdmission(); onAdmissionReset?()
        timer?.invalidate(); timer = nil; startupDeadline?.cancel(); startTask?.cancel()
        // No native acquisition has begun: invalidate immediately. Discovery may
        // remain suspended, but its attempt can never install or start resources.
        guard capture.hasResources else {
            attempt = nil; startTask = nil; ownsMicrophone = false; onMicrophoneReleased?()
            present(.failed(stage: "Preparation", message: errorMessage ?? "No media captured", retainedMedia: false))
            return
        }
        present(.processing, captureID: capture.snapshot()?.id)
        var presentation = presentationID
        let pendingStart = startTask
        let microphoneStop = Task { [weak self] in
            await pendingStart?.value
            await capture.stopMicrophone()
            guard let self, self.attempt === capture else { return }
            self.ownsMicrophone = false; self.onMicrophoneReleased?()
        }
        let finalizer = self.finalizer
        let repairAudio = self.repairAudio
        Task { [weak self] in
            await microphoneStop.value
            await Task.detached { capture.finishAudio() }.value
            await capture.finishVideo()
            await capture.drainJournal()
            guard let self else { return }
            defer {
                if self.attempt === capture { self.attempt = nil; self.startTask = nil }
            }
            guard let manifest = capture.snapshot() else {
                if self.attempt === capture, self.presentationID == presentation {
                    self.present(.failed(stage: "Preparation", message: self.errorMessage ?? "No media captured", retainedMedia: false))
                }
                return
            }
            let id = manifest.id
            if !discard { self.latestID = id }
            do {
                let result = try await Task.detached { () throws -> (manifest: FeedbackCaptureManifest, retainsContent: Bool)? in
                    if discard {
                        capture.store.release(id: id); try capture.store.delete(id: id); return nil
                    }
                    // Successful writers already established their media. Probe
                    // uncertain outputs independently, including partial failures.
                    return capture.store.reconcileMedia(manifest,
                        audioDuration: { manifest.audio == nil ? try repairAudio($0) : nil },
                        videoDuration: { manifest.video == nil ? try Self.videoDuration($0) : nil })
                }.value
                if let result {
                    let completed = try await finalizer.finish(result.manifest,
                        context: .init(store: capture.store, finishPasteboardChangeCount: changeCount))
                    if self.attempt === capture, self.presentationID == presentation {
                        if let failure = completed.failures.first {
                            self.present(.failed(stage: failure.stage, message: failure.message,
                                retainedMedia: result.retainsContent || completed.audio != nil || completed.video != nil), captureID: id)
                        } else { self.present(completed.state == .ready ? .ready : .failed(stage: "Recording", message: "No media captured", retainedMedia: false), captureID: id) }
                    }
                } else if self.attempt === capture, self.presentationID == presentation { self.present(nil) }
            } catch {
                self.errorMessage = error.localizedDescription
                if self.attempt === capture, self.presentationID == presentation {
                    self.present(.failed(stage: "Saving", message: error.localizedDescription, retainedMedia: true), captureID: id)
                }
            }
            await Task.detached { capture.store.release(id: id) }.value
            await self.reload()
        }
        Task { [weak self] in
            guard let self else { return }
            let completed = await self.waitUntil { self.attempt !== capture }
            if !completed, self.attempt === capture, self.presentationID == presentation {
                let id = capture.snapshot()?.id
                self.present(.failed(stage: self.ownsMicrophone ? "Microphone teardown" : "Media finalization",
                    message: "Finalization is still pending", retainedMedia: id != nil), captureID: id)
                presentation = self.presentationID
            }
        }
    }
    private func waitUntil(_ complete: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: waiterTimeout)
        while !complete() {
            if Task.isCancelled || ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
    /// Deadlines release callers only; actual teardown owns the microphone and files.
    @discardableResult func finishAndReleaseMicrophone() async -> Bool {
        finish()
        let released = await waitUntil { !ownsMicrophone }
        if !released { errorMessage = "Microphone teardown timed out" }
        return released
    }
    @discardableResult func shutdown() async -> Bool {
        finish()
        let completed = await waitUntil { attempt == nil && recoveryTask == nil }
        if !completed { errorMessage = "Feedback finalization timed out" }
        return completed
    }
    @discardableResult func reload(requestedID: String? = nil) async -> Bool {
        guard let store else { return false }
        catalogRequestID &+= 1
        let request = catalogRequestID
        do {
            let loaded = try await Task.detached {
                var records = try store.list()
                if let requestedID, let record = try store.get(id: requestedID) {
                    records.removeAll { $0.id == requestedID }; records.insert(record, at: 0)
                }
                return records
            }.value
            guard catalogRequestID == request else { return false }
            records = loaded; return true
        } catch {
            if catalogRequestID == request { errorMessage = error.localizedDescription }
            return false
        }
    }
    func open(id: String? = nil) {
        let requested = id ?? presentedCaptureID ?? latestID
        if let openCapture { openCapture(requested); return }
        Task {
            guard await reload(requestedID: requested) else { return }
            if windowController == nil { windowController = FeedbackCaptureWindowController(controller: self) }
            windowController?.show(id: requested)
        }
    }
    func delete(id: String) async throws {
        if let store { try await Task.detached { try store.delete(id: id) }.value }
        await reload()
        if latestID == id { latestID = records.first?.id }
        if presentedCaptureID == id { present(nil) }
    }
    func powerLevel() -> Float { attempt?.meter(now: Date()).1 ?? -160 }
    private func present(_ state: FeedbackCapturePillState?, captureID: String? = nil) {
        dismissal?.cancel(); dismissal = nil; presentationID &+= 1
        presentedCaptureID = captureID
        let identity = presentationID
        self.state = state; onStateChanged?(state)
        if state?.isComplete == true || { if case .busy = state { return true }; return false }() {
            dismissal = Task { [weak self] in
                try? await Task.sleep(for: self?.dismissalDelay ?? .seconds(25))
                guard !Task.isCancelled, self?.presentationID == identity else { return }
                self?.present(nil)
            }
        }
    }
}
