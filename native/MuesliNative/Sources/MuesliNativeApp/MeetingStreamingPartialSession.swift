import AVFoundation
import FluidAudio
import Foundation
import os

enum MeetingLiveCaptionModelStore {
    static let repo = Repo.parakeetEou320
    static let sizeLabel = "~430 MB"
    static let label = "Parakeet Realtime EOU"

    static func cacheRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    static func modelDirectory(fileManager: FileManager = .default) -> URL {
        modelDirectory(in: cacheRoot(fileManager: fileManager))
    }

    static func isDownloaded(fileManager: FileManager = .default) -> Bool {
        isDownloaded(in: cacheRoot(fileManager: fileManager), fileManager: fileManager)
    }

    static func modelDirectory(in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    static func isDownloaded(in cacheRoot: URL, fileManager: FileManager = .default) -> Bool {
        let directory = modelDirectory(in: cacheRoot)
        return ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func download(
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await DownloadUtils.downloadRepo(repo, to: cacheRoot()) { update in
            progress?(update.fractionCompleted)
        }
    }

    static func delete(fileManager: FileManager = .default) throws {
        let directory = modelDirectory(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    static func makeEngine(label: String) async throws -> MeetingStreamingPartialEngine {
        let engine = ParakeetEOUMeetingPartialEngine(label: label)
        try await engine.loadModels(from: modelDirectory())
        return engine
    }

    static func makeEngines(
        backend: MeetingLiveCaptionBackend,
        nemotronPromptId: Int32
    ) async throws -> (mic: MeetingStreamingPartialEngine, system: MeetingStreamingPartialEngine) {
        switch backend {
        case .parakeetRealtimeEOU:
            let mic = try await makeEngine(label: "You")
            do {
                return (mic, try await makeEngine(label: "Others"))
            } catch {
                await mic.shutdown()
                throw error
            }
        case .nemotron35:
            guard #available(macOS 15, *) else {
                throw NSError(
                    domain: "MeetingLiveCaptions",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Nemotron 3.5 requires macOS 15 or later."]
                )
            }
            let transcriber = Nemotron35StreamingTranscriber()
            await transcriber.setPromptId(nemotronPromptId)
            try await transcriber.loadModels()
            let mic = Nemotron35MeetingPartialEngine(transcriber: transcriber, label: "You")
            let system = Nemotron35MeetingPartialEngine(transcriber: transcriber, label: "Others")
            do {
                try await mic.prepare()
                try await system.prepare()
                return (mic, system)
            } catch {
                await mic.shutdown()
                await system.shutdown()
                await transcriber.shutdown()
                throw error
            }
        }
    }
}

protocol MeetingStreamingPartialEngine: AnyObject, Sendable {
    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async
    func process(samples: [Float]) async throws
    func finish() async throws
    func shutdown() async
}

extension MeetingStreamingPartialEngine {
    func finish() async throws {}
}

private actor ParakeetEOUMeetingPartialEngine: MeetingStreamingPartialEngine {
    private let manager = StreamingEouAsrManager(chunkSize: .ms320)
    private let label: String

    init(label: String) {
        self.label = label
    }

    func loadModels(from directory: URL) async throws {
        try await manager.loadModels(from: directory)
    }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(handler)
    }

    func process(samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "MeetingLiveCaptions",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate a 16 kHz live-caption buffer."]
            )
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        _ = try await manager.process(audioBuffer: buffer)
    }

    func shutdown() async {
        await manager.cleanup()
        fputs("[meeting-partials] \(label) Parakeet EOU session stopped\n", stderr)
    }
}

@available(macOS 15, *)
private actor Nemotron35MeetingPartialEngine: MeetingStreamingPartialEngine {
    private let transcriber: Nemotron35StreamingTranscriber
    private let label: String
    private var streamState: Nemotron35StreamingTranscriber.StreamState?
    private var sampleBuffer: [Float] = []
    private var transcript = ""
    private var partialHandler: (@Sendable (String) -> Void)?

    init(transcriber: Nemotron35StreamingTranscriber, label: String) {
        self.transcriber = transcriber
        self.label = label
    }

    func prepare() async throws {
        streamState = try await transcriber.makeStreamState()
    }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        partialHandler = handler
    }

    func process(samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        sampleBuffer.append(contentsOf: samples)
        let chunkSize = transcriber.chunkSamples
        while sampleBuffer.count >= chunkSize {
            let chunk = Array(sampleBuffer.prefix(chunkSize))
            sampleBuffer.removeFirst(chunkSize)
            guard var state = streamState else {
                throw Nemotron35StreamingTranscriber.TranscriberError.notLoaded
            }
            let text = try await transcriber.transcribeChunk(samples: chunk, state: &state)
            streamState = state
            guard !text.isEmpty else { continue }
            transcript += text
            partialHandler?(transcript)
        }
    }

    func finish() async throws {
        guard !sampleBuffer.isEmpty else { return }
        let chunkSize = transcriber.chunkSamples
        sampleBuffer.append(contentsOf: repeatElement(0, count: max(chunkSize - sampleBuffer.count, 0)))
        if sampleBuffer.count >= chunkSize {
            let chunk = Array(sampleBuffer.prefix(chunkSize))
            sampleBuffer.removeFirst(chunkSize)
            guard var state = streamState else {
                throw Nemotron35StreamingTranscriber.TranscriberError.notLoaded
            }
            let text = try await transcriber.transcribeChunk(samples: chunk, state: &state)
            streamState = state
            if !text.isEmpty {
                transcript += text
                partialHandler?(transcript)
            }
        }
    }

    func shutdown() async {
        sampleBuffer.removeAll()
        transcript = ""
        streamState = nil
        partialHandler = nil
        fputs("[meeting-partials] \(label) Nemotron 3.5 session stopped\n", stderr)
    }
}

/// Display-only streaming partials for one meeting audio source ("You" or "Others").
///
/// The session receives the same 16 kHz samples as the existing meeting VAD and
/// chunk recorders. Parakeet EOU supplies a low-latency cumulative transcript,
/// while VAD rotation and durable chunk transcription remain authoritative:
/// `markSegmentBoundary(id:)` freezes the provisional prefix and
/// `commitSegment(id:)` removes it only after that chunk retires.
final class MeetingStreamingPartialSession: @unchecked Sendable {
    /// Called with the current provisional tail text on a background thread.
    /// An empty string clears the tail.
    var onPartialUpdate: ((String) -> Void)?

    /// Feed the EOU manager at its 320 ms shift cadence. The manager retains the
    /// larger look-ahead window required by its cache-aware encoder.
    static let feedSamples = StreamingChunkSize.ms320.shiftSamples
    static let maxQueuedChunks = 3
    static let publicationIntervalNanoseconds: UInt64 = 250_000_000
    static let finishDrainTimeoutNanoseconds: UInt64 = 30_000_000_000

    private let engine: MeetingStreamingPartialEngine
    private let label: String

    private struct PendingSegment {
        let id: UUID
        let prefixLength: Int
        var isCommitted = false
    }

    private struct State {
        var sampleBuffer: [Float] = []
        var chunkQueue: [[Float]] = []
        var isDraining = false
        var engineText = ""
        var committedPrefixLength = 0
        var pendingSegments: [PendingSegment] = []
        var isStopped = false
        var isSuspended = false
        var didFail = false
        var pendingPublicationTail: String?
        var lastPublishedTail: String?
        var isPublicationScheduled = false
        var lifecycleRevision: UInt64 = 0
        var activeInferenceRevision: UInt64?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(engine: MeetingStreamingPartialEngine, label: String) {
        self.engine = engine
        self.label = label
    }

    func connect() async {
        await engine.setPartialHandler { [weak self] text in
            self?.receiveEnginePartial(text)
        }
    }

    /// Cheap append called from the existing meeting audio queue. Inference is
    /// single-flight and bounded so provisional captions cannot delay recording.
    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let shouldStartDrain = state.withLock { s -> Bool in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return false }
            s.sampleBuffer.append(contentsOf: samples)
            while s.sampleBuffer.count >= Self.feedSamples {
                s.chunkQueue.append(Array(s.sampleBuffer.prefix(Self.feedSamples)))
                s.sampleBuffer.removeFirst(Self.feedSamples)
            }
            if s.chunkQueue.count > Self.maxQueuedChunks {
                s.chunkQueue.removeFirst(s.chunkQueue.count - Self.maxQueuedChunks)
            }
            guard !s.chunkQueue.isEmpty, !s.isDraining else { return false }
            s.isDraining = true
            return true
        }
        if shouldStartDrain {
            Task.detached(priority: .utility) { [weak self] in
                await self?.drain()
            }
        }
    }

    func markSegmentBoundary(id: UUID) {
        state.withLock { s in
            s.pendingSegments.append(PendingSegment(id: id, prefixLength: s.engineText.count))
        }
    }

    func pendingSegmentText(id: UUID) -> String? {
        state.withLock { s in
            guard !s.isStopped, !s.didFail,
                  let segmentIndex = s.pendingSegments.firstIndex(where: { $0.id == id }) else { return nil }
            let segment = s.pendingSegments[segmentIndex]
            let previousPrefixLength = segmentIndex > 0
                ? s.pendingSegments[segmentIndex - 1].prefixLength
                : s.committedPrefixLength
            let startOffset = min(previousPrefixLength, s.engineText.count)
            let endOffset = min(max(segment.prefixLength, startOffset), s.engineText.count)
            guard endOffset > startOffset else { return nil }
            let start = s.engineText.index(s.engineText.startIndex, offsetBy: startOffset)
            let end = s.engineText.index(s.engineText.startIndex, offsetBy: endOffset)
            let text = String(s.engineText[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    func commitSegment(id: UUID) {
        let publication: (tail: String, revision: UInt64)? = state.withLock { s in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return nil }
            guard let segmentIndex = s.pendingSegments.firstIndex(where: { $0.id == id }) else { return nil }
            s.pendingSegments[segmentIndex].isCommitted = true
            var didAdvance = false
            while let first = s.pendingSegments.first, first.isCommitted {
                s.committedPrefixLength = max(
                    s.committedPrefixLength,
                    min(first.prefixLength, s.engineText.count)
                )
                s.pendingSegments.removeFirst()
                didAdvance = true
            }
            guard didAdvance else { return nil }
            return (visibleTail(for: s), s.lifecycleRevision)
        }
        if let publication {
            publishImmediately(publication.tail, expectedRevision: publication.revision)
        }
    }

    /// Pause uses the existing VAD/chunk boundary as the durable commit point.
    /// Buffered audio is dropped and the current engine prefix is hidden; the
    /// cache-aware model state remains warm for a low-latency resume.
    func suspend() {
        state.withLock { s in
            s.isSuspended = true
            s.lifecycleRevision &+= 1
            s.sampleBuffer.removeAll(keepingCapacity: true)
            s.chunkQueue.removeAll(keepingCapacity: true)
            s.committedPrefixLength = s.engineText.count
            s.pendingSegments.removeAll(keepingCapacity: true)
        }
        publishImmediately("")
    }

    func resume() {
        state.withLock { s in
            s.isSuspended = false
        }
    }

    func finish(
        drainTimeoutNanoseconds: UInt64 = MeetingStreamingPartialSession.finishDrainTimeoutNanoseconds
    ) async -> String? {
        let shouldDrain = state.withLock { s -> Bool in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return false }
            if !s.sampleBuffer.isEmpty {
                s.sampleBuffer.append(contentsOf: repeatElement(0, count: Self.feedSamples - s.sampleBuffer.count))
                s.chunkQueue.append(s.sampleBuffer)
                s.sampleBuffer.removeAll(keepingCapacity: true)
            }
            guard !s.chunkQueue.isEmpty, !s.isDraining else { return false }
            s.isDraining = true
            return true
        }
        if shouldDrain {
            Task.detached(priority: .utility) { [weak self] in
                await self?.drain()
            }
        }
        let drainDeadline = DispatchTime.now().uptimeNanoseconds &+ drainTimeoutNanoseconds
        while state.withLock({ $0.isDraining || !$0.chunkQueue.isEmpty }) {
            guard DispatchTime.now().uptimeNanoseconds < drainDeadline else {
                goDormant(error: NSError(
                    domain: "MeetingStreamingPartialSession",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out finalizing live transcript audio."]
                ))
                return nil
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !state.withLock({ $0.didFail || $0.isStopped }) else { return nil }
        let finishRevision = state.withLock { s -> UInt64 in
            s.activeInferenceRevision = s.lifecycleRevision
            return s.lifecycleRevision
        }
        do {
            try await engine.finish()
        } catch {
            goDormant(error: error)
            return nil
        }
        state.withLock { s in
            if s.activeInferenceRevision == finishRevision {
                s.activeInferenceRevision = nil
            }
        }
        return state.withLock { s in
            let text = visibleTail(for: s).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    func stop() {
        state.withLock { s in
            s.isStopped = true
            s.lifecycleRevision &+= 1
            s.sampleBuffer.removeAll()
            s.chunkQueue.removeAll()
            s.engineText = ""
            s.committedPrefixLength = 0
            s.pendingSegments.removeAll()
            s.pendingPublicationTail = nil
            s.activeInferenceRevision = nil
        }
        publishImmediately("")
        Task { await engine.shutdown() }
    }

    private func drain() async {
        while true {
            let work: (chunk: [Float], revision: UInt64)? = state.withLock { s in
                guard !s.isStopped, !s.isSuspended, !s.didFail, !s.chunkQueue.isEmpty else {
                    s.isDraining = false
                    return nil
                }
                let revision = s.lifecycleRevision
                s.activeInferenceRevision = revision
                return (s.chunkQueue.removeFirst(), revision)
            }
            guard let work else { return }

            do {
                try await engine.process(samples: work.chunk)
                state.withLock { s in
                    if s.activeInferenceRevision == work.revision {
                        s.activeInferenceRevision = nil
                    }
                }
            } catch {
                goDormant(error: error)
                return
            }
        }
    }

    private func receiveEnginePartial(_ text: String) {
        let filteredText = TranscriptionEngineArtifactsFilter.apply(text)
        let tail: String? = state.withLock { s in
            guard !s.isStopped, !s.isSuspended, !s.didFail,
                  s.activeInferenceRevision == s.lifecycleRevision else { return nil }
            if filteredText.count < s.committedPrefixLength {
                s.committedPrefixLength = 0
                s.pendingSegments.removeAll()
            }
            s.engineText = filteredText
            return visibleTail(for: s)
        }
        if let tail {
            schedulePublication(tail)
        }
    }

    private func goDormant(error: Error) {
        state.withLock { s in
            s.didFail = true
            s.lifecycleRevision &+= 1
            s.isDraining = false
            s.sampleBuffer.removeAll()
            s.chunkQueue.removeAll()
            s.engineText = ""
            s.committedPrefixLength = 0
            s.pendingSegments.removeAll()
            s.activeInferenceRevision = nil
        }
        fputs("[meeting-partials] \(label) session dormant after error: \(error)\n", stderr)
        publishImmediately("")
        Task { await engine.shutdown() }
    }

    /// Core ML may produce partials faster than SwiftUI can lay out a long live
    /// transcript. Keep one delayed publication per source and replace its
    /// payload with the newest tail instead of queueing main-actor work.
    private func schedulePublication(_ tail: String) {
        let shouldSchedule = state.withLock { s -> Bool in
            guard !s.isStopped, !s.isSuspended, !s.didFail else { return false }
            guard tail != s.lastPublishedTail || s.pendingPublicationTail != nil else { return false }
            s.pendingPublicationTail = tail
            guard !s.isPublicationScheduled else { return false }
            s.isPublicationScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: Self.publicationIntervalNanoseconds)
            self?.flushScheduledPublication()
        }
    }

    private func flushScheduledPublication() {
        let tail: String? = state.withLock { s in
            s.isPublicationScheduled = false
            guard !s.isStopped, !s.isSuspended, !s.didFail,
                  let pending = s.pendingPublicationTail else {
                s.pendingPublicationTail = nil
                return nil
            }
            s.pendingPublicationTail = nil
            guard pending != s.lastPublishedTail else { return nil }
            s.lastPublishedTail = pending
            return pending
        }
        if let tail {
            onPartialUpdate?(tail)
        }
    }

    private func publishImmediately(_ tail: String, expectedRevision: UInt64? = nil) {
        let shouldPublish = state.withLock { s -> Bool in
            if let expectedRevision, expectedRevision != s.lifecycleRevision {
                return false
            }
            s.pendingPublicationTail = nil
            guard tail != s.lastPublishedTail else { return false }
            s.lastPublishedTail = tail
            return true
        }
        if shouldPublish {
            onPartialUpdate?(tail)
        }
    }

    private func visibleTail(for state: State) -> String {
        let dropCount = min(state.committedPrefixLength, state.engineText.count)
        return String(state.engineText.dropFirst(dropCount))
    }
}
