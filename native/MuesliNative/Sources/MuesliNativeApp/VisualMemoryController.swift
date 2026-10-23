import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import Observation
import ImageIO
import MuesliCore

@MainActor @Observable
final class VisualMemoryController {
    var items: [VisualMemoryItem] = []
    var browsableMoments: [VisualMemoryItem] = []
    var incompleteMomentCount = 0
    var catalogRevision = 0
    var message: String?
    var messageMeetingID: Int64?
    private var recordedSessions: Set<UUID> = []
    private var sessionClipIDs: [UUID: Set<String>] = [:]
    private var recordingSessionID: UUID?
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
    var ambientPaused = false
    var ambientStatus = "Off" {
        didSet {
            if !ambientStatus.hasPrefix("On") { onAmbientCaptureActivity?(false) }
            guard let store, let data = try? JSONSerialization.data(withJSONObject: [
                "status": ambientStatus, "updated_at_unix": Date().timeIntervalSince1970
            ]) else { return }
            try? data.write(to: store.root.appendingPathComponent("capture-health.json"), options: .atomic)
        }
    }
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
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var ambientConfig: AppConfig?
    @ObservationIgnored private var ambientGeneration = UUID()
    @ObservationIgnored private var lastFingerprint: Data?
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored private var lastSource = ""
    @ObservationIgnored private var lastCompaction = Date.distantPast
    @ObservationIgnored private var compactionRunning = false

    init(databaseURL: URL, supportDirectory: URL = AppIdentity.supportDirectoryURL) {
        do {
            meetingStore = try MeetingVideoStore(databaseURL: databaseURL,
                root: supportDirectory.appendingPathComponent("meeting-recordings/videos"))
        } catch { message = error.localizedDescription }
        // Legacy migration is optional; its failure must not disable new captures.
        let legacyRoot = supportDirectory.appendingPathComponent("visual-memory")
        do { store = try VisualMemoryStore(root: legacyRoot) }
        catch { NSLog("Screen history catalog unavailable: %@", error.localizedDescription) }
        reload()
        let videos = meetingStore, legacy = store
        maintenanceTask = Task { [weak self] in
            await Task.detached(priority: .utility) {
                do {
                    try videos?.maintain(recoverRecording: Self.recoverableDuration)
                    if let legacy { try videos?.migrateLegacyVideos(from: legacy) }
                } catch { NSLog("Meeting video recovery: %@", error.localizedDescription) }
            }.value
            self?.reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard self != nil else { return }
                await Task.detached(priority: .utility) {
                    do { try videos?.maintain(recoverRecording: Self.recoverableDuration) } catch { NSLog("Meeting video cleanup: %@", error.localizedDescription) }
                }.value
                self?.reload()
            }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspendForPrivacy() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspendForPrivacy() }
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

    func reload() {
        do {
            let videos = try meetingStore?.items() ?? []
            let migratedIDs = Set(videos.map(\.id))
            items = ((try? store?.items()) ?? []).filter { !migratedIDs.contains($0.id) } + videos
            browsableMoments = items.filter { item in
                guard item.kind == .moment, let url = mediaURL(item), FileManager.default.fileExists(atPath: url.path) else { return false }
                if item.frameIndex != nil { return true }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Int,
                      let height = props[kCGImagePropertyPixelHeight] as? Int else { return false }
                return width >= 100 && height >= 100
            }
            incompleteMomentCount = items.filter { $0.kind == .moment }.count - browsableMoments.count
            catalogRevision += 1
            updateSpace()
        }
        catch { message = error.localizedDescription }
    }
    func mediaURL(_ item: VisualMemoryItem) -> URL? {
        if item.kind == .meetingVideo, let url = try? meetingStore?.url(for: item.path), FileManager.default.fileExists(atPath: url.path) { return url }
        return try? store?.url(for: item.path)
    }
    func updateSpace() {
        guard let root = meetingStore?.root else { return }
        freeBytes = ((try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
    }
    var usedBytes: Int64 {
        var paths = Set<String>()
        return items.reduce(0) { sum, item in sum + (paths.insert(item.path).inserted ? item.bytes : 0) }
    }
    func delete(_ item: VisualMemoryItem) {
        do {
            let ids = Set(items.filter { $0.kind == item.kind && $0.path == item.path }.map(\.id))
            if item.kind == .meetingVideo { try meetingStore?.delete(ids: ids) }
            try store?.delete(ids: ids)
            reload()
        } catch { message = error.localizedDescription }
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
        updateSpace()
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
        ambientConfig = config
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
        ambientPaused.toggle(); locked = false; ambientGeneration = UUID()
        ambientTask?.cancel(); ambientTask = nil
        lastFingerprint = nil
        if let config = ambientConfig { configureAmbient(config, audioFallbackActive: audioFallbackActive) }
    }

    private var isInactive: Bool {
        guard ambientConfig?.timeTurnerPauseOnInactivity != false else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!) >= 60
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
        if let element = DictationContextCapture.focusedUIElement(for: app),
           DictationContextCapture.axStringValue(element, attribute: kAXSubroleAttribute as String) == "AXSecureTextField" {
            ambientStatus = "Skipping private content"; lastFingerprint = nil; return
        }
        do {
            try enforceAmbientRetention()
            updateSpace()
            guard freeBytes > 2_000_000_000 else { ambientStatus = "Paused — disk space low"; return }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let focused = DictationContextCapture.focusedWindowSnapshot(for: app, allowTitleFallback: false),
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
            guard generation == ambientGeneration, !Task.isCancelled, !ambientPaused, !locked, !isInactive,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  DictationContextCapture.focusedWindowSnapshot(for: app, allowTitleFallback: false)?.frame == frame,
                  DictationContextCapture.focusedWindowSnapshot(for: app, allowTitleFallback: false)?.title == focused.title else { return }
            ambientStatus = "On · this Mac"
            onAmbientCaptureActivity?(true)
            let source = [app.localizedName ?? bundle, title].filter { !$0.isEmpty }.joined(separator: " · ")
            if result.fingerprint == lastFingerprint && result.text == lastText && source == lastSource {
                ambientStatus = "On · screen unchanged"; return
            }
            let path = UUID().uuidString + ".heic"
            let url = try store.url(for: path)
            try result.data.write(to: url, options: .atomic)
            do { try store.save([VisualMemoryItem(kind: .moment, capturedAt: captured, source: source, bundleID: bundle,
                text: result.text, path: path, bytes: Int64(result.data.count), captureCompletedAt: captureCompleted, pixelWidth: image.width, pixelHeight: image.height)]) }
            catch { try? FileManager.default.removeItem(at: url); throw error }
            lastFingerprint = result.fingerprint; lastText = result.text; lastSource = source
            reload(); ambientStatus = "On · this Mac"
            await compactAmbientIfNeeded()
        } catch { ambientStatus = "Capture unavailable"; message = error.localizedDescription }
    }

    private func enforceAmbientRetention() throws {
        guard let store else { return }
        let moments = items.filter { $0.kind == .moment }
        var paths = Set(moments.filter { $0.capturedAt < Date().addingTimeInterval(-7 * 86400) }.map(\.path))
        let groups = Dictionary(grouping: moments, by: \.path)
        let budget = Int64(ambientConfig?.timeTurnerBudget ?? "10") ?? 10
        var total = groups.values.reduce(Int64(0)) { $0 + ($1.first?.bytes ?? 0) }
        for group in groups.values.sorted(by: { ($0.first?.capturedAt ?? .distantPast) < ($1.first?.capturedAt ?? .distantPast) }) {
            guard let first = group.first else { continue }
            if paths.contains(first.path) || total > budget * 1_000_000_000 {
                paths.insert(first.path); total -= first.bytes
            }
        }
        if !paths.isEmpty {
            try store.delete(ids: Set(moments.filter { paths.contains($0.path) }.map(\.id))); reload()
        }
    }

    private func compactAmbientIfNeeded() async {
        guard !compactionRunning, Date().timeIntervalSince(lastCompaction) > 300,
              !ProcessInfo.processInfo.isLowPowerModeEnabled, let store else { return }
        lastCompaction = Date()
        let candidates = items.filter { $0.kind == .moment && $0.frameIndex == nil && $0.capturedAt < Date().addingTimeInterval(-600) }.sorted { $0.capturedAt < $1.capturedAt }
        guard let first = candidates.first else { return }
        let batch = Array(candidates.filter { $0.source == first.source }.prefix(100))
        guard batch.count >= 25 else { return }
        compactionRunning = true
        defer { compactionRunning = false }
        let path = UUID().uuidString + ".mp4"
        do {
            let urls = try batch.map { try store.url(for: $0.path) }
            let output = try store.url(for: path)
            try await Task.detached(priority: .utility) { try await VisualMemoryEncoding.compact(images: urls, destination: output) }.value
            let latest = try store.items()
            guard batch.allSatisfy({ original in latest.contains(where: { $0.id == original.id && $0.path == original.path }) }) else {
                try? FileManager.default.removeItem(at: output); return
            }
            let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
            let originals = batch.reduce(Int64(0)) { $0 + $1.bytes }
            guard bytes < originals else { try FileManager.default.removeItem(at: output); return }
            let packed = batch.enumerated().map { index, original in
                var item = original; item.path = path; item.frameIndex = index; item.bytes = bytes; return item
            }
            try store.save(packed)
            for url in urls { try? FileManager.default.removeItem(at: url) }
            reload()
        } catch { message = "History compaction deferred: \(error.localizedDescription)" }
    }

    func suspendForPrivacy() {
        locked = true; ambientPaused = true
        if let id = recordingMeetingID {
            messageMeetingID = id; message = "Screen recording paused while the Mac was locked or asleep."
            pauseState.userPaused = true; reconcilePause()
        }
        ambientStatus = "Paused — resume manually"
    }
}
