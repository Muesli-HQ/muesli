import AppKit
import Foundation
import MuesliCore

/// Later slices register only the stages they produce. Copy always follows durable publication.
struct FeedbackCaptureFinalizer {
    enum StageName: Int, CaseIterable, Sendable { case transcribe, keyframes, render, summary, copy }
    struct Context: Sendable {
        let store: FeedbackCaptureStore
        let finishPasteboardChangeCount: Int
        var thumbnails: [FeedbackCaptureContext.Thumbnail] = []
        var delivery = FeedbackCaptureDelivery()
        var preserveSavedImages = false
    }
    struct Stage {
        let name: StageName
        let run: (inout FeedbackCaptureManifest, Context) async throws -> Void
    }
    var stages: [Stage] = []
    var prepareThumbnails: ((FeedbackCaptureManifest, Context) async throws -> [FeedbackCaptureContext.Thumbnail])?

    private struct SavedImages: Sendable {
        let keyframes: [FeedbackCaptureKeyframe]
        let contactSheet: String?
    }

    private static func readableSavedImages(_ manifest: FeedbackCaptureManifest, store: FeedbackCaptureStore) -> SavedImages {
        func isReadable(_ path: String) -> Bool {
            guard let url = try? store.mediaURL(id: manifest.id, path: path),
                  let data = try? Data(contentsOf: url),
                  NSBitmapImageRep(data: data) != nil else { return false }
            return true
        }
        return SavedImages(
            keyframes: manifest.keyframes.filter { isReadable($0.file) },
            contactSheet: manifest.contactSheet.flatMap { isReadable($0) ? $0 : nil })
    }

    private func prepare(_ manifest: FeedbackCaptureManifest, context: Context) async -> Result<[FeedbackCaptureContext.Thumbnail], Error>? {
        guard let prepareThumbnails else { return nil }
        do { return .success(try await prepareThumbnails(manifest, context)) }
        catch { return .failure(error) }
    }
    func finish(_ recording: FeedbackCaptureManifest, context: Context, completionState: FeedbackCaptureState = .ready) async throws -> FeedbackCaptureManifest {
        var manifest = recording, context = context
        manifest.state = .processing
        let preparationContext = context, store = context.store
        async let preparation = prepare(recording, context: preparationContext)
        let processing = manifest
        try await Task.detached { try store.checkpoint(processing); try store.save(processing) }.value
        for name in StageName.allCases where name != .copy {
            if name == .keyframes, let prepared = await preparation {
                switch prepared {
                case .success(let thumbnails): context.thumbnails = thumbnails
                case .failure(let error):
                    if completionState == .recovered {
                        let saved = await Task.detached(priority: .utility) {
                            Self.readableSavedImages(recording, store: store)
                        }.value
                        manifest.keyframes = saved.keyframes
                        manifest.contactSheet = saved.contactSheet
                        context.preserveSavedImages = !saved.keyframes.isEmpty || saved.contactSheet != nil
                    }
                    manifest.failures.append(.init(stage: "keyframes", message: error.localizedDescription))
                }
            }
            for stage in stages where stage.name == name {
                do { try await stage.run(&manifest, context) }
                catch { manifest.failures.append(.init(stage: String(describing: name), message: error.localizedDescription)) }
                let checkpoint = manifest
                try await Task.detached { try store.checkpoint(checkpoint) }.value
            }
        }
        manifest.state = manifest.audio != nil || manifest.video != nil || (!manifest.events.isEmpty || !manifest.strokes.isEmpty) ? completionState : .failed
        let published = manifest
        try await Task.detached { try store.publish(published) }.value
        // Recovery reconstructs local artifacts but never replaces the user's clipboard.
        for stage in stages where stage.name == .copy && completionState != .recovered && manifest.state != .failed {
            do { try await stage.run(&manifest, context) }
            catch {
                context.delivery.result = .failed
                manifest.failures.append(.init(stage: "copy", message: error.localizedDescription))
            }
            let delivered = manifest
            try await Task.detached { try store.publish(delivered) }.value
        }
        return manifest
    }
}

/// One job owns its result continuation. Expiry/cancellation retires publication
/// immediately; native work keeps its own permit/files until it actually returns.
actor FeedbackCaptureTranscriptionJob {
    @TaskLocal static var current: FeedbackCaptureTranscriptionJob?
    private var remaining: Duration = .zero
    private var activeSince: ContinuousClock.Instant?
    private var timerID = UUID()
    private var result: CheckedContinuation<FeedbackCaptureTranscript, Never>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func run(timeout: Duration = .seconds(600),
             operation: @escaping @Sendable () async throws -> FeedbackCaptureTranscript) async -> FeedbackCaptureTranscript {
        guard !Task.isCancelled else { return .unavailable("transcription cancelled") }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                result = continuation
                remaining = timeout
                worker = Task(priority: .background) {
                    let value: FeedbackCaptureTranscript
                    do { value = try await Self.$current.withValue(self, operation: operation) }
                    catch is CancellationError { value = .unavailable("transcription cancelled") }
                    catch { value = .unavailable(error.localizedDescription) }
                    complete(value)
                }
            }
        } onCancel: { Task { await self.expire("transcription cancelled") } }
    }

    /// Only the coordinator's preparation/decoding sections consume this job's budget.
    func setActive(_ active: Bool) {
        if let activeSince { remaining -= activeSince.duration(to: .now) }
        activeSince = nil
        timer?.cancel(); timer = nil
        timerID = UUID()
        guard result != nil else { return }
        guard remaining > .zero else { expire("transcription timed out after ten minutes"); return }
        guard active else { return }
        activeSince = .now
        let id = timerID, delay = remaining
        timer = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            if timerID == id { expire("transcription timed out after ten minutes") }
        }
    }

    static func withActiveWork<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        await current?.setActive(true)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await current?.setActive(false)
            return value
        } catch {
            await current?.setActive(false)
            throw error
        }
    }

    private func expire(_ reason: String) {
        worker?.cancel()
        complete(.unavailable(reason))
    }
    private func complete(_ value: FeedbackCaptureTranscript) {
        guard let result else { return }
        self.result = nil
        timer?.cancel(); timer = nil
        worker = nil
        result.resume(returning: value)
    }
}

extension FeedbackCaptureFinalizer {
    static func transcriptionStage(
        transcribe: @escaping @Sendable (URL) async throws -> FeedbackCaptureTranscript
    ) -> Stage {
        Stage(name: .transcribe) { manifest, context in
            guard manifest.transcript == nil else { return }
            let transcript: FeedbackCaptureTranscript
            if let audio = manifest.audio {
                let url = try context.store.mediaURL(id: manifest.id, path: audio)
                transcript = await FeedbackCaptureTranscriptionJob().run { try await transcribe(url) }
            } else { transcript = .unavailable("narration audio unavailable") }
            manifest.transcript = transcript
            if let missing = transcript.missing {
                manifest.failures.append(.init(stage: "transcribe", message: missing.reason))
            }
        }
    }
}

/// Delivery is transient: it describes this clipboard attempt, never a durable
/// promise about clipboard contents after a restart.
final class FeedbackCaptureDelivery: @unchecked Sendable {
    enum Result: Equatable, Sendable { case copied, skipped, failed }
    private let lock = NSLock()
    private var value: Result?
    var result: Result? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    @MainActor static func write(_ summary: String, to pasteboard: NSPasteboard, unchangedSince: Int? = nil) -> Result {
        if let unchangedSince, pasteboard.changeCount != unchangedSince { return .skipped }
        pasteboard.clearContents()
        return pasteboard.setString(summary, forType: .string) ? .copied : .failed
    }
}
extension FeedbackCaptureFinalizer {
    static func prepareContextThumbnails(_ manifest: FeedbackCaptureManifest, context: Context) async throws -> [FeedbackCaptureContext.Thumbnail] {
        guard let video = manifest.video else { return [] }
        let url = try context.store.mediaURL(id: manifest.id, path: video)
        let cancellation = FeedbackCaptureDecodeCancellation()
        return try await FeedbackCaptureMediaJob<[FeedbackCaptureContext.Thumbnail]>().run(timeout: .seconds(5), cancel: cancellation.cancel) {
            try await FeedbackCaptureMediaLimiter.thumbnails.perform {
                try await FeedbackCaptureRenderer.thumbnails(url: url, videoOffsetMs: manifest.videoOffsetMs ?? 0, cancellation: cancellation)
            }
        }
    }
    static func contextStages() -> [Stage] {
        [
            .init(name: .keyframes) { manifest, context in
                guard !context.preserveSavedImages else { return }
                if !manifest.strokes.isEmpty, !context.thumbnails.isEmpty {
                    let splits = FeedbackCaptureContext.markSplitBeforeStrokeIndices(strokes: manifest.strokes, thumbnails: context.thumbnails)
                    manifest.marks = FeedbackCaptureInk.marks(manifest.strokes, splitBeforeStrokeIndices: splits)
                }
                let candidates = FeedbackCaptureContext.select(durationMs: manifest.durationMs, events: manifest.events, thumbnails: context.thumbnails, marks: manifest.marks)
                manifest.keyframes = FeedbackCaptureContext.keyframes(candidates, transcript: manifest.transcript)
                for (candidate, frame) in zip(candidates, manifest.keyframes) {
                    for index in manifest.marks.indices where candidate.markIds.contains(manifest.marks[index].id) {
                        manifest.marks[index].frame = frame.file
                    }
                }
                manifest.contactSheet = nil
            },
            .init(name: .render) { manifest, context in
                guard !context.preserveSavedImages else { return }
                let selected = manifest
                // A failed or expired decoder must not publish paths to nonexistent images.
                manifest.keyframes = []; manifest.contactSheet = nil
                // Retain group membership in `selected`; clear every published link until writes succeed.
                for index in manifest.marks.indices { manifest.marks[index].frame = nil }
                guard let video = selected.video, !selected.keyframes.isEmpty else { return }
                let url = try context.store.mediaURL(id: selected.id, path: video)
                let cancellation = FeedbackCaptureDecodeCancellation()
                let output = try await FeedbackCaptureMediaJob<FeedbackCaptureRenderer.Output>().run(timeout: .seconds(30), cancel: cancellation.cancel) {
                    try await FeedbackCaptureMediaLimiter.render.perform {
                        try await FeedbackCaptureRenderer.render(selected, url: url, cancellation: cancellation)
                    }
                }
                let writer = Task.detached(priority: .utility) { try write(output, id: selected.id, store: context.store) }
                let written = try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
                manifest.keyframes = written.frames.map(\.keyframe)
                manifest.marks = selected.marks
                FeedbackCaptureContext.linkMarks(&manifest)
                manifest.contactSheet = written.contactSheet == nil ? nil : "contact-sheet.png"
                manifest.failures += written.failures
            },
            .init(name: .summary) { manifest, context in
                let snapshot = manifest
                let writer = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let summary = FeedbackCaptureContext.summary(snapshot, bundle: try context.store.bundleURL(id: snapshot.id))
                    try Data(summary.utf8).write(to: context.store.mediaURL(id: snapshot.id, path: "summary.md"), options: .atomic)
                }
                try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
            }
        ]
    }
    private static func write(_ output: FeedbackCaptureRenderer.Output, id: String, store: FeedbackCaptureStore) throws -> FeedbackCaptureRenderer.Output {
        try Task.checkCancellation()
        guard store.isActive(id: id) else { throw CancellationError() }
        var written = FeedbackCaptureRenderer.Output(frames: [], contactSheet: nil, failures: output.failures)
        if !output.frames.isEmpty {
            try FileManager.default.createDirectory(at: store.mediaURL(id: id, path: "frames"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for frame in output.frames {
            try Task.checkCancellation()
            do {
                try frame.png.write(to: store.mediaURL(id: id, path: frame.keyframe.file), options: .atomic)
                written.frames.append(frame)
            } catch { written.failures.append(.init(stage: "render", message: "Frame #\(frame.keyframe.index): \(error.localizedDescription)")) }
        }
        if let sheet = output.contactSheet {
            try Task.checkCancellation()
            do {
                try sheet.write(to: store.mediaURL(id: id, path: "contact-sheet.png"), options: .atomic)
                written.contactSheet = sheet
            } catch { written.failures.append(.init(stage: "render", message: "Contact sheet: \(error.localizedDescription)")) }
        }
        return written
    }
    @MainActor static func copyStage(pasteboard: NSPasteboard = .general,
        load: @escaping @Sendable (URL) async throws -> String = { url in
            try await Task.detached(priority: .utility) { try String(contentsOf: url, encoding: .utf8) }.value
        }) -> Stage {
        let write: @MainActor (String, Int) -> FeedbackCaptureDelivery.Result = { summary, count in
            FeedbackCaptureDelivery.write(summary, to: pasteboard, unchangedSince: count)
        }
        return .init(name: .copy) { manifest, context in
            let url = try context.store.mediaURL(id: manifest.id, path: "summary.md")
            let summary = try await load(url)
            try Task.checkCancellation()
            let result = await write(summary, context.finishPasteboardChangeCount)
            context.delivery.result = result
            if result == .failed { throw ScreenVideoRecorder.error("Cannot copy feedback summary") }
        }
    }
}
