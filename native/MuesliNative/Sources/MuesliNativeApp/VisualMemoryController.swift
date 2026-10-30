import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import Observation
import MuesliCore

@MainActor @Observable
final class VisualMemoryController {
    var items: [VisualMemoryItem] = []
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
    @ObservationIgnored private var filter: SCContentFilter?
    @ObservationIgnored private var meetingStart = Date()
    @ObservationIgnored private var clipStart = Date()
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(databaseURL: URL, supportDirectory: URL = AppIdentity.supportDirectoryURL) {
        do {
            meetingStore = try MeetingVideoStore(databaseURL: databaseURL,
                root: supportDirectory.appendingPathComponent("meeting-recordings/videos"))
        } catch { message = error.localizedDescription }
        // Legacy migration is optional; its failure must not disable new captures.
        let legacyRoot = supportDirectory.appendingPathComponent("visual-memory")
        if FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("catalog.sqlite").path) {
            do { store = try VisualMemoryStore(root: legacyRoot) }
            catch { NSLog("Legacy video catalog unavailable: %@", error.localizedDescription) }
        }
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
    func suspendForPrivacy() {
        if let id = recordingMeetingID {
            messageMeetingID = id; message = "Screen recording paused while the Mac was locked or asleep."
            pauseState.userPaused = true; reconcilePause()
        }
    }
}
