import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import Observation
import ImageIO
import MuesliCore

/// System suspension is independent of the user's explicit pause choice.
struct TimeTurnerPauseState {
    var userPaused = false
    var sleeping = false
    var screenLocked = false
    var systemSuspended: Bool { sleeping || screenLocked }
    var isPaused: Bool { userPaused || systemSuspended }
}

@MainActor @Observable
final class VisualMemoryController {
    var items: [VisualMemoryItem] = []
    var usedBytes: Int64 = 0
    var averageImageBytes: Int64?
    @ObservationIgnored private var summaryRevision: String?
    struct HistoryApp: Identifiable, Sendable {
        let id: String
        let name: String
    }
    var historyApps: [HistoryApp] = []
    var catalogRevision = 0
    var message: String?
    var messageMeetingID: Int64?
    private var recordedSessions: Set<UUID> = []
    private var sessionClipIDs: [UUID: Set<String>] = [:]
    private var recordingSessionID: UUID?
    @ObservationIgnored private var initializationTask: Task<Void, Never>?
    @ObservationIgnored private var spaceTask: Task<Int64, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    var recordingMeetingID: Int64?
    var isAwaitingConfirmation = false
    var isPreparing = false
    var isFinalizing = false
    var pauseState = ScreenRecordingPauseState()
    var sourceName = ""
    @ObservationIgnored var onAmbientCaptureActivity: ((Bool) -> Void)?
    var ambientIndicatorActive: Bool {
        ambientConfig?.timeTurnerEnabled == true && !ambientPaused && !locked && !isInactive
            && recordingMeetingID == nil && !audioFallbackActive && ambientStatus.hasPrefix("On")
    }
    private var ambientPauseState = TimeTurnerPauseState()
    var ambientPaused: Bool { ambientPauseState.userPaused }
    var ambientStatus = "Off" {
        didSet {
            guard ambientStatus != oldValue else { return }
            if !ambientStatus.hasPrefix("On") { onAmbientCaptureActivity?(false) }
            guard let store, let data = try? JSONSerialization.data(withJSONObject: [
                "status": ambientStatus, "updated_at_unix": Date().timeIntervalSince1970
            ]) else { return }
            let url = store.root.appendingPathComponent("capture-health.json")
            healthWriteQueue.async { try? data.write(to: url, options: .atomic) }
        }
    }
    @ObservationIgnored private let healthWriteQueue = DispatchQueue(label: "muesli.capture-health", qos: .utility)
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadGeneration = 0
    var freeBytes: Int64 = 0
    let audioRouter = ScreenAudioRouter()
    @ObservationIgnored private(set) var store: VisualMemoryStore?
    @ObservationIgnored private var meetingStore: MeetingVideoStore?
    @ObservationIgnored private var recorder: ScreenVideoRecorder?
    @ObservationIgnored private var recordingItem: VisualMemoryItem?
    @ObservationIgnored var flushRecordingAudio: (() -> Void)?
    @ObservationIgnored private var announcementSound: NSSound?
    @ObservationIgnored private var confirmationWindow: NSWindow?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var audioFallbackActive = false
    @ObservationIgnored private var filter: SCContentFilter?
    @ObservationIgnored private var meetingStart = Date()
    @ObservationIgnored private var clipStart = Date()
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var ambientTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private var locked: Bool { ambientPauseState.systemSuspended }
    @ObservationIgnored private var ambientConfig: AppConfig?
    @ObservationIgnored private var ambientGeneration = UUID()
    @ObservationIgnored private var lastFingerprint: Data?
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored private var lastSource = ""
    @ObservationIgnored private var lastCompaction = Date.distantPast
    @ObservationIgnored private var compactionRunning = false
    @ObservationIgnored private var invalidCompactionIDs: Set<String> = []
    @ObservationIgnored private var lastCompactionValidationReset = Date()

    private let databaseURL: URL
    @ObservationIgnored private var retentionTask: Task<Void, Never>?

    init(databaseURL: URL, supportDirectory: URL = AppIdentity.supportDirectoryURL) {
        self.databaseURL = databaseURL
        initializationTask = Task { [weak self] in
            let stores = await Task.detached(priority: .utility) {
                let videos = Result { try MeetingVideoStore(databaseURL: databaseURL,
                    root: supportDirectory.appendingPathComponent("meeting-recordings/videos")) }
                let legacy = Result { try VisualMemoryStore(root: supportDirectory.appendingPathComponent("visual-memory")) }
                return (videos, legacy)
            }.value
            guard let self else { return }
            do { self.meetingStore = try stores.0.get() } catch { self.message = error.localizedDescription }
            do { self.store = try stores.1.get() } catch { NSLog("Screen history catalog unavailable: %@", error.localizedDescription) }
            self.reload()
        }
        maintenanceTask = Task { [weak self] in
            await self?.initializationTask?.value
            let videos = self?.meetingStore, legacy = self?.store
            await Task.detached(priority: .utility) {
                do {
                    try videos?.maintain(recoverRecording: Self.recoverableDuration)
                    if let legacy { try videos?.migrateLegacyVideos(from: legacy) }
                } catch { NSLog("Meeting video recovery: %@", error.localizedDescription) }
            }.value
            await self?.maintainAmbientHistory()
            self?.reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard self != nil else { return }
                await Task.detached(priority: .utility) {
                    do { try videos?.maintain(recoverRecording: Self.recoverableDuration) } catch { NSLog("Meeting video cleanup: %@", error.localizedDescription) }
                }.value
                await self?.maintainAmbientHistory()
                self?.reload()
            }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAmbientSystemSuspension(sleeping: true) }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAmbientSystemSuspension(screenLocked: true) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAmbientSystemSuspension(sleeping: false) }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setAmbientSystemSuspension(screenLocked: false) }
        })
    }

    // Called only on the utility maintenance task, never during UI rendering.
    nonisolated private static func recoverableDuration(_ url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        guard asset.isPlayable, !asset.tracks(withMediaType: .video).isEmpty else { return nil }
        let duration = CMTimeGetSeconds(asset.duration)
        return duration.isFinite && duration > 0 ? duration : nil
    }

    func hasMedia(meetingID: Int64) -> Bool {
        // On a read error preserve the meeting rather than deleting potentially retained video.
        (try? meetingStore?.hasMedia(meetingID: meetingID)) ?? true
    }

    func refreshCatalog() async {
        await initializationTask?.value
        reload()
        await reloadTask?.value
    }

    func reload() {
        reloadGeneration += 1
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reloadTask = nil }
            while !Task.isCancelled {
                let generation = self.reloadGeneration
                let store = self.store, meetingStore = self.meetingStore
                do {
                    let snapshot = try await Task.detached(priority: .utility) {
                        (try meetingStore?.items() ?? [], try store?.summary())
                    }.value
                    if generation == self.reloadGeneration {
                        if self.items != snapshot.0 { self.items = snapshot.0 }
                        if self.summaryRevision != snapshot.1?.revision {
                            self.summaryRevision = snapshot.1?.revision
                            self.historyApps = (snapshot.1?.apps ?? [:]).map { HistoryApp(id: $0.key, name: $0.value) }
                                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                            self.usedBytes = snapshot.1?.mediaBytes ?? 0
                            self.averageImageBytes = snapshot.1?.averageImageBytes
                            self.catalogRevision += 1
                        }
                        self.updateSpace()
                    }
                } catch { if generation == self.reloadGeneration { self.message = error.localizedDescription } }
                if generation == self.reloadGeneration { return }
            }
        }
    }

    func mediaURL(_ item: VisualMemoryItem) -> URL? {
        guard item.mediaDeletedAt == nil else { return nil }
        if item.kind == .meetingVideo, let url = try? meetingStore?.url(for: item.path), FileManager.default.fileExists(atPath: url.path) { return url }
        return try? store?.url(for: item.path)
    }
    func updateSpace() {
        Task { [weak self] in await self?.refreshSpace() }
    }
    private func refreshSpace() async {
        if let spaceTask { freeBytes = await spaceTask.value; return }
        let root = databaseURL.deletingLastPathComponent()
        let task = Task.detached(priority: .utility) {
            ((try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
        }
        spaceTask = task
        freeBytes = await task.value
        spaceTask = nil
    }
    /// Selected-day reads run off the main actor and retain OCR-only observations.
    func moments(on day: Date) async throws -> [VisualMemoryItem] {
        await initializationTask?.value
        guard let interval = Calendar.current.dateInterval(of: .day, for: day), let store else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            try store.moments(from: interval.start, until: interval.end)
        }.value
    }

    func delete(_ item: VisualMemoryItem) {
        let store = store, videos = meetingStore, databaseURL = databaseURL
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    if item.kind == .meetingVideo {
                        try videos?.delete(ids: [item.id])
                        try store?.delete(ids: [item.id])
                    } else if let store {
                        // Shared archives are forgotten as a unit, including their OCR and recaps.
                        let ids = try store.momentIDs(mediaPath: item.path)
                        try TimeTurnerRetention.delete(ids: ids, store: store, databaseURL: databaseURL)
                    }
                }.value
                reload()
            } catch { message = error.localizedDescription }
        }
    }

    func deleteMeeting(_ id: Int64) throws {
        let ids = Set(items.filter { $0.meetingID == id }.map(\.id))
        try meetingStore?.delete(ids: ids)
        try store?.delete(ids: ids)
        reload()
    }
    func deleteAllMeetings() throws {
        let ids = Set(items.filter { $0.kind == .meetingVideo }.map(\.id))
        try meetingStore?.delete(ids: ids)
        try store?.delete(ids: ids)
        reload()
    }

    func requestRecording(meetingID: Int64, sessionID: UUID, startedAt: Date, presentationWindow: NSWindow, isStillActive: @escaping () -> Bool) {
        guard recordingMeetingID == nil, !isPreparing, !isFinalizing else { return }
        isPreparing = true; message = nil; messageMeetingID = meetingID; token = UUID()
        let attempt = token
        startTask = Task {
            defer { if token == attempt { isPreparing = false } }
            do {
                await initializationTask?.value
                guard token == attempt, isStillActive() else { return }
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                    throw ScreenVideoRecorder.error("Allow Screen Recording in System Settings, then try again.")
                }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard token == attempt, isStillActive() else { return }
                let sources = content.windows.compactMap { window -> MeetingScreenSource? in
                    guard let app = window.owningApplication,
                          app.processID != ProcessInfo.processInfo.processIdentifier,
                          window.windowLayer == 0, window.frame.width > 100, window.frame.height > 100,
                          NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular else { return nil }
                    return MeetingScreenSource(id: "window-\(window.windowID)", title: app.applicationName,
                        subtitle: window.title?.isEmpty == false ? window.title! : "Untitled window",
                        filter: SCContentFilter(desktopIndependentWindow: window), isDisplay: false,
                        icon: NSRunningApplication(processIdentifier: app.processID)?.icon)
                }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                + content.displays.enumerated().map { index, display in
                    MeetingScreenSource(id: "display-\(display.displayID)", title: "Display \(index + 1)",
                        subtitle: "\(display.width) × \(display.height)",
                        filter: SCContentFilter(display: display, excludingWindows: []), isDisplay: true,
                        icon: NSImage(systemSymbolName: "display", accessibilityDescription: nil))
                }
                guard !sources.isEmpty else { throw ScreenVideoRecorder.error("No screen source is available.") }
                guard presentationWindow.isVisible, presentationWindow.attachedSheet == nil else {
                    throw ScreenVideoRecorder.error("Close the current dialog, then try Record Screen again.")
                }
                isAwaitingConfirmation = true
                let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 748, height: 588),
                                     styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                sheet.title = "Record meeting screen"
                sheet.isReleasedWhenClosed = false
                confirmationWindow = sheet
                var selection: MeetingScreenSource?
                var announce = false
                sheet.contentViewController = NSHostingController(rootView: MeetingScreenSourcePicker(sources: sources) { source, playAnnouncement in
                    selection = source
                    announce = playAnnouncement
                    presentationWindow.endSheet(sheet, returnCode: source == nil ? .cancel : .OK)
                })
                NSApp.activate(ignoringOtherApps: true)
                presentationWindow.makeKeyAndOrderFront(nil)
                let response = await withCheckedContinuation { continuation in
                    presentationWindow.beginSheet(sheet) { response in continuation.resume(returning: response) }
                }
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                confirmationWindow = nil
                isAwaitingConfirmation = false
                guard response == .OK, let selection, token == attempt, isStillActive() else { return }
                filter = selection.filter
                sourceName = "\(selection.title) — \(selection.subtitle)"
                meetingStart = startedAt; recordingMeetingID = meetingID; recordingSessionID = sessionID; pauseState = .init()
                try await beginClip(attempt: attempt)
                recordedSessions.insert(sessionID)
                // The optional announcement must never gate capture or its retention.
                if announce, token == attempt, isStillActive() {
                    announcementSound?.stop()
                    if let clip = Bundle.module.url(forResource: "recording-announcement", withExtension: "aiff"),
                       let audioFile = try? AVAudioFile(forReading: clip), audioFile.length > 0,
                       let sound = NSSound(contentsOf: clip, byReference: false), sound.play() {
                        announcementSound = sound
                    } else {
                        message = "Announcement could not play. Screen recording continues; please notify participants manually."
                    }
                }
            } catch { message = error.localizedDescription; recordingMeetingID = nil; filter = nil }
        }
    }

    private func beginClip(attempt: UUID) async throws {
        guard let store = meetingStore else { throw ScreenVideoRecorder.error("Meeting video storage is unavailable. Please restart muesli and try again.") }
        guard token == attempt, recorder == nil, let filter, recordingMeetingID != nil, !pauseState.isPaused else { return }
        await refreshSpace()
        guard token == attempt, recorder == nil, recordingMeetingID != nil, !pauseState.isPaused else { return }
        guard freeBytes > 2_000_000_000 else { throw ScreenVideoRecorder.error("Screen recording needs at least 2 GB of free disk space.") }
        let url = try store.url(for: UUID().uuidString + ".mp4")
        let recording = ScreenVideoRecorder(url: url)
        recording.onFailure = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.token == attempt else { return }
                self.message = reason; await self.stopRecording()
            }
        }
        clipStart = Date()
        let item = VisualMemoryItem(kind: .meetingVideo, meetingID: recordingMeetingID, capturedAt: clipStart,
            source: sourceName, path: url.lastPathComponent, meetingOffset: max(0, clipStart.timeIntervalSince(meetingStart)))
        try store.beginRecording(item)
        recordingItem = item
        if let sessionID = recordingSessionID { sessionClipIDs[sessionID, default: []].insert(item.id) }
        recorder = recording; audioRouter.set(recording)
        let scale = Double(filter.pointPixelScale)
        let rect = filter.contentRect
        let factor = min(1, 2560 / max(1, rect.width * scale))
        do { try await recording.start(filter: filter, width: Int(rect.width * scale * factor), height: Int(rect.height * scale * factor)) }
        catch {
            audioRouter.set(nil); recorder = nil; recordingItem = nil
            store.endRecording(item)
            try? store.delete(ids: [item.id]) // durable cleanup survives a failed removal
            throw error
        }

    }
    private func finishClip(discard: Bool = false) async {
        if let pending = finalizationTask { await pending.value; return }
        guard let recording = recorder, var item = recordingItem else { return }
        flushRecordingAudio?()
        recorder = nil; recordingItem = nil; audioRouter.set(nil); isFinalizing = true
        let videos = meetingStore, pendingItem = item
        recording.onFinalized = { videos?.endRecording(pendingItem) }
        let task = Task {
            defer { isFinalizing = false }
            do {
                item.duration = try await recording.stop()
                if !discard {
                    item.bytes = (try FileManager.default.attributesOfItem(atPath: recording.url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard let meetingStore else { throw ScreenVideoRecorder.error("Video storage is unavailable.") }
                    let completed = item
                    try await Task.detached(priority: .utility) { try meetingStore.persistCompleted(completed) }.value
                    reload()
                }
            } catch {
                messageMeetingID = item.meetingID
                message = "Screen recording was interrupted. Its file and recovery information were retained: \(error.localizedDescription)"
            }
            if discard {
                meetingStore?.endRecording(item)
                let videos = meetingStore, id = item.id
                do {
                    try await Task.detached(priority: .utility) { try videos?.delete(ids: [id]) }.value
                } catch { message = "Video cleanup will be retried: \(error.localizedDescription)" }
            }
        }
        finalizationTask = task
        await task.value
        finalizationTask = nil
    }
    func stopRecording(discard: Bool = false) async {
        token = UUID()
        announcementSound?.stop()
        announcementSound = nil
        if let sheet = confirmationWindow, let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: .cancel)
        }
        let pendingStart = startTask
        await pendingStart?.value
        startTask = nil; isPreparing = false
        await finishClip(discard: discard)
        recordingMeetingID = nil; recordingSessionID = nil; filter = nil; pauseState = .init()
    }
    func hasRecording(in sessionID: UUID) -> Bool { recordedSessions.contains(sessionID) }

    func discardSession(_ sessionID: UUID) async {
        if recordingSessionID == sessionID { await stopRecording(discard: true) }
        let ids = sessionClipIDs.removeValue(forKey: sessionID) ?? []
        let videos = meetingStore
        do {
            try await Task.detached(priority: .utility) { try videos?.delete(ids: ids) }.value
        } catch { message = "Could not remove discarded video: \(error.localizedDescription)" }
        recordedSessions.remove(sessionID)
        reload()
    }

    func toggleScreenPause() {
        guard recordingMeetingID != nil, !isFinalizing, !isPreparing else { return }
        pauseState.userPaused.toggle(); reconcilePause()
    }
    func setMeetingPaused(_ value: Bool) {
        guard recordingMeetingID != nil else { return }
        pauseState.meetingPaused = value; reconcilePause()
    }
    private func reconcilePause() {
        let attempt = token
        Task {
            await startTask?.value
            await finalizationTask?.value
            guard token == attempt else { return }
            if pauseState.isPaused { await finishClip() }
            else if recorder == nil {
                do { try await beginClip(attempt: attempt) }
                catch { message = error.localizedDescription; await stopRecording() }
            }
        }
    }
    func configureAmbient(_ config: AppConfig, audioFallbackActive: Bool) {
        self.audioFallbackActive = audioFallbackActive
        let changed = ambientConfig?.timeTurnerEnabled != config.timeTurnerEnabled
            || ambientConfig?.timeTurnerPauseOnInactivity != config.timeTurnerPauseOnInactivity
            || ambientConfig?.timeTurnerInterval != config.timeTurnerInterval
            || ambientConfig?.timeTurnerBudget != config.timeTurnerBudget
            || ambientConfig?.timeTurnerExcludedApps != config.timeTurnerExcludedApps
        let retentionChanged = ambientConfig?.timeTurnerRetentionPolicy != config.timeTurnerRetentionPolicy
        ambientConfig = config
        if retentionChanged {
            Task { [weak self] in
                await self?.maintainAmbientHistory()
                self?.reload()
            }
        }
        if !config.timeTurnerEnabled || audioFallbackActive {
            ambientTask?.cancel(); ambientTask = nil; ambientGeneration = UUID()
            ambientStatus = audioFallbackActive && config.timeTurnerEnabled ? "Paused during meeting audio capture" : "Off"
            return
        }
        if changed { ambientTask?.cancel(); ambientTask = nil; ambientGeneration = UUID() }
        guard ambientTask == nil else { return }
        ambientStatus = "Starting"
        let generation = ambientGeneration
        ambientTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.captureMoment(generation: generation)
                let seconds = Double(self.ambientConfig?.timeTurnerInterval ?? "10") ?? 10
                do { try await Task.sleep(for: .seconds(self.ambientStatus == "Paused — inactive" ? 2 : max(2, seconds))) } catch { return }
            }
        }
    }

    func toggleAmbientPause() {
        ambientPauseState.userPaused.toggle(); ambientGeneration = UUID()
        ambientTask?.cancel(); ambientTask = nil
        lastFingerprint = nil
        if let config = ambientConfig { configureAmbient(config, audioFallbackActive: audioFallbackActive) }
    }

    private var isInactive: Bool {
        guard ambientConfig?.timeTurnerPauseOnInactivity != false else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) >= 60
    }

    private nonisolated static func ambientWindow(processID: pid_t) async -> (secure: Bool, window: DictationContextCapture.FocusedWindowSnapshot?) {
        await Task.detached(priority: .utility) {
            guard let app = NSRunningApplication(processIdentifier: processID) else { return (true, nil) }
            var secure = false
            if let element = DictationContextCapture.focusedUIElement(for: app, messagingTimeout: 0.5) {
                AXUIElementSetMessagingTimeout(element, 0.5)
                secure = DictationContextCapture.axStringValue(element, attribute: kAXSubroleAttribute as String) == "AXSecureTextField"
            }
            return (secure, DictationContextCapture.focusedWindowSnapshot(for: app, allowTitleFallback: false, messagingTimeout: 0.5))
        }.value
    }

    private func captureMoment(generation: UUID) async {
        guard generation == ambientGeneration, !Task.isCancelled else { return }
        guard !ambientPaused, !locked else { ambientStatus = "Paused"; return }
        guard !isInactive else { ambientStatus = "Paused — inactive"; return }
        guard recordingMeetingID == nil else { ambientStatus = "Paused during screen recording"; return }
        guard ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else {
            ambientStatus = "Paused to reduce heat"; return
        }
        guard CGPreflightScreenCaptureAccess() else { ambientStatus = "Screen Recording permission needed"; return }
        guard let store, let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier else { return }
        let excluded = [Bundle.main.bundleIdentifier ?? "", "com.apple.systempreferences", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7"]
        let customExcluded = (ambientConfig?.timeTurnerExcludedApps ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !customExcluded.contains(bundle), !excluded.contains(bundle) else { ambientStatus = "Skipping this app"; lastFingerprint = nil; return }
        let pid = app.processIdentifier
        let before = await Self.ambientWindow(processID: pid)
        guard generation == ambientGeneration, !Task.isCancelled else { return }
        guard !before.secure else { ambientStatus = "Skipping private content"; lastFingerprint = nil; return }
        do {
            await refreshSpace()
            guard freeBytes > 2_000_000_000 else { ambientStatus = "Paused — disk space low"; return }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let focused = before.window,
                  let frame = focused.frame,
                  let window = content.windows.first(where: { $0.owningApplication?.processID == app.processIdentifier && VisualMemoryWindowMatch.matches(candidate: $0.frame, focused: frame, layer: Int($0.windowLayer)) }) else {
                ambientStatus = "Waiting for a visible window"; return
            }
            guard window.frame.width >= 100, window.frame.height >= 100 else {
                ambientStatus = "Waiting for a full window"; return
            }
            let title = window.title ?? ""
            guard !["incognito", "private browsing", "inprivate"].contains(where: { title.localizedCaseInsensitiveContains($0) }) else {
                ambientStatus = "Skipping private window"; return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = max(2, Int(window.frame.width * CGFloat(filter.pointPixelScale)))
            configuration.height = max(2, Int(window.frame.height * CGFloat(filter.pointPixelScale)))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.scalesToFit = true
            let captured = Date()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let captureCompleted = Date()
            guard image.width == configuration.width, image.height == configuration.height,
                  image.width >= 100, image.height >= 100 else {
                throw ScreenVideoRecorder.error("Screen capture returned unexpected dimensions; no image was saved.")
            }
            let result = try await Task.detached(priority: .utility) { try VisualMemoryEncoding.encode(.init(image: image)) }.value
            let after = await Self.ambientWindow(processID: pid)
            guard !after.secure, generation == ambientGeneration, !Task.isCancelled, !ambientPaused, !locked, !isInactive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  after.window?.frame == frame,
                  after.window?.title == focused.title else { return }
            ambientStatus = "On · this Mac"
            onAmbientCaptureActivity?(true)
            let source = [app.localizedName ?? bundle, title].filter { !$0.isEmpty }.joined(separator: " · ")
            if result.fingerprint == lastFingerprint && result.text == lastText && source == lastSource {
                ambientStatus = "On · screen unchanged"; return
            }
            let path = UUID().uuidString + ".heic"
            let item = VisualMemoryItem(kind: .moment, capturedAt: captured, source: source, bundleID: bundle,
                text: result.text, path: path, bytes: Int64(result.data.count), captureCompletedAt: captureCompleted,
                pixelWidth: image.width, pixelHeight: image.height, appName: app.localizedName ?? bundle, windowTitle: title)
            try await Task.detached(priority: .utility) {
                let url = try store.url(for: path)
                try result.data.write(to: url, options: .atomic)
                do { try store.save([item]) }
                catch { try? FileManager.default.removeItem(at: url); throw error }
            }.value
            guard generation == ambientGeneration, !Task.isCancelled, !locked, !ambientPaused else {
                try await Task.detached(priority: .utility) { try store.delete(ids: [item.id]) }.value
                return
            }
            lastFingerprint = result.fingerprint; lastText = result.text; lastSource = source
            await refreshCatalog(); ambientStatus = "On · this Mac"
            await compactAmbientIfNeeded()
        } catch { ambientStatus = "Capture unavailable"; message = error.localizedDescription }
    }

    /// Runs independently of capture gates; settings changes also schedule an immediate pass.
    private func maintainAmbientHistory() async {
        if let running = retentionTask { await running.value; return }
        guard let store, let policy = ambientConfig?.timeTurnerRetentionPolicy else { return }
        let databaseURL = databaseURL
        let task = Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try TimeTurnerRetention.maintain(store: store, databaseURL: databaseURL, policy: policy)
                }.value
            } catch { self?.message = "History cleanup will retry: \(error.localizedDescription)" }
        }
        retentionTask = task
        await task.value
        retentionTask = nil
    }

    private func compactAmbientIfNeeded() async {
        guard !compactionRunning, Date().timeIntervalSince(lastCompaction) > 300,
              !ProcessInfo.processInfo.isLowPowerModeEnabled, let store else { return }
        lastCompaction = Date()
        compactionRunning = true
        defer { compactionRunning = false }
        let mayRetryInvalid = Date().timeIntervalSince(lastCompactionValidationReset) >= 3600
        let skipped = invalidCompactionIDs
        let batch: [VisualMemoryItem]
        do {
            let selection = try await Task.detached(priority: .utility) {
                var excluded = skipped
                // Finish progressing through later candidates before revisiting damaged ones.
                // Otherwise a large damaged prefix could consume every hourly retry window.
                var reset = false
                if mayRetryInvalid && !excluded.isEmpty { reset = try store.compactionBatch(excludingIDs: excluded).isEmpty }
                if reset { excluded.removeAll() }
                let rows = try VisualMemoryEncoding.compactionBatch(store: store, excluding: &excluded)
                return (rows, excluded, reset)
            }.value
            batch = selection.0
            invalidCompactionIDs = selection.1
            if selection.2 { lastCompactionValidationReset = Date() }
        } catch { message = error.localizedDescription; return }
        guard !batch.isEmpty else { return }
        do {
            try await Task.detached(priority: .utility) {
                let output = try store.url(for: UUID().uuidString + ".mp4")
                var committed = false
                defer { if !committed { try? FileManager.default.removeItem(at: output) } }
                let urls = try batch.map { try store.url(for: $0.path) }
                try await VisualMemoryEncoding.compact(images: urls, destination: output)
                let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
                let originals = batch.reduce(Int64(0)) { $0 + $1.bytes }
                guard bytes < originals else { return }
                let packed = batch.enumerated().map { index, original in
                    var item = original; item.path = output.lastPathComponent; item.frameIndex = index; item.bytes = bytes; return item
                }
                // Atomic source validation prevents retention/deletion from being undone.
                guard try store.replaceMedia(packed, ifUnchanged: batch) else { return }
                committed = true
                for url in urls { try? FileManager.default.removeItem(at: url) }
            }.value
            reload()
        } catch { message = "History compaction deferred: \(error.localizedDescription)" }
    }

    private func setAmbientSystemSuspension(sleeping: Bool? = nil, screenLocked: Bool? = nil) {
        if let sleeping { ambientPauseState.sleeping = sleeping }
        if let screenLocked { ambientPauseState.screenLocked = screenLocked }
        // Invalidate work begun before sleep/lock, including a capture still awaiting OCR.
        ambientGeneration = UUID()
        ambientTask?.cancel(); ambientTask = nil
        if locked, let id = recordingMeetingID {
            messageMeetingID = id; message = "Screen recording paused while the Mac was locked or asleep."
            pauseState.userPaused = true; reconcilePause()
        }
        // Meeting video remains manually paused; only ambient capture resumes.
        if let config = ambientConfig { configureAmbient(config, audioFallbackActive: audioFallbackActive) }
        if ambientConfig?.timeTurnerEnabled == true, ambientPauseState.isPaused {
            ambientStatus = "Paused"
        }
    }
}
