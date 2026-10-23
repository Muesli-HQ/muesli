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
    @ObservationIgnored private var announcementSound: NSSound?
    @ObservationIgnored private var confirmationWindow: NSWindow?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var finalizationTask: Task<Void, Never>?
    @ObservationIgnored private var filter: SCContentFilter?
    @ObservationIgnored private var meetingStart = Date()
    @ObservationIgnored private var clipStart = Date()
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(databaseURL: URL) {
        do {
            store = try VisualMemoryStore(root: AppIdentity.supportDirectoryURL.appendingPathComponent("visual-memory"))
            meetingStore = try MeetingVideoStore(databaseURL: databaseURL,
                root: AppIdentity.supportDirectoryURL.appendingPathComponent("meeting-recordings/videos"))
            if let store {
                do { try meetingStore?.migrateLegacyVideos(from: store) }
                catch { message = "Some older videos could not be moved: \(error.localizedDescription)" }
            }
            reload()
        }
        catch { message = error.localizedDescription }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspendForPrivacy() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspendForPrivacy() }
        })
    }

    func reload() {
        do {
            let videos = try meetingStore?.items() ?? []
            let migratedIDs = Set(videos.map(\.id))
            items = try (store?.items() ?? []).filter { !migratedIDs.contains($0.id) } + videos
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
        guard let root = store?.root else { return }
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

    func requestRecording(meetingID: Int64, startedAt: Date, presentationWindow: NSWindow, isStillActive: @escaping () -> Bool) {
        guard recordingMeetingID == nil, !isPreparing, !isFinalizing else { return }
        isPreparing = true; message = nil; token = UUID()
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
                meetingStart = startedAt; recordingMeetingID = meetingID; pauseState = .init()
                try await beginClip(attempt: attempt)
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
        guard token == attempt, recorder == nil, let filter, let store = meetingStore, recordingMeetingID != nil, !pauseState.isPaused else { return }
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
        recorder = recording; clipStart = Date(); audioRouter.set(recording)
        let scale = Double(filter.pointPixelScale)
        let rect = filter.contentRect
        let factor = min(1, 2560 / max(1, rect.width * scale))
        do { try await recording.start(filter: filter, width: Int(rect.width * scale * factor), height: Int(rect.height * scale * factor)) }
        catch { audioRouter.set(nil); recorder = nil; try? FileManager.default.removeItem(at: url); throw error }

    }
    private func finishClip(discard: Bool = false) async {
        if let pending = finalizationTask { await pending.value; return }
        guard let recording = recorder else { return }
        recorder = nil; audioRouter.set(nil); isFinalizing = true
        let owner = recordingMeetingID, start = clipStart, source = sourceName
        let offset = max(0, start.timeIntervalSince(meetingStart))
        let task = Task {
        defer { isFinalizing = false }
        do {
            let duration = try await recording.stop()
            if discard { try? FileManager.default.removeItem(at: recording.url); return }
            let bytes = (try FileManager.default.attributesOfItem(atPath: recording.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            try meetingStore?.save([VisualMemoryItem(kind: .meetingVideo, meetingID: owner, capturedAt: start, source: source,
                path: recording.url.lastPathComponent, duration: duration, meetingOffset: offset, bytes: bytes)])
            reload()
        } catch {
            try? FileManager.default.removeItem(at: recording.url)
            message = "Screen recording: \(error.localizedDescription)"
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
        recordingMeetingID = nil; filter = nil; pauseState = .init()
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
        if recordingMeetingID != nil { pauseState.userPaused = true; reconcilePause() }
    }
}
