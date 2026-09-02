import AVFoundation
import FluidAudio
import Foundation
import MuesliCore
import os
import Speech

enum MeetingLiveCaptionModelStore {
    static let repo = Repo.parakeetEou320
    static let modelID = "FluidInference/parakeet-realtime-eou-120m-coreml/320ms"
    static let sizeLabel = "~430 MB"
    static let label = "Parakeet Live Captions"

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
        ManagedASRModelPlans.parakeetRealtimeEOU320(modelsRoot: cacheRoot)
            .isAvailableLocally(fileManager: fileManager)
    }

    static func download(
        progress: (@Sendable (Double) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        _ = try await ManagedASRModelDownloader.downloadIfNeeded(
            ManagedASRModelPlans.parakeetRealtimeEOU320(),
            progress: { fraction, _ in progress?(fraction) },
            progressSnapshot: progressSnapshot
        )
    }

    static func delete(fileManager: FileManager = .default) throws {
        try ManagedASRModelPlans.parakeetRealtimeEOU320(
            modelsRoot: cacheRoot(fileManager: fileManager)
        ).delete(fileManager: fileManager)
    }

    static func makeEngine(label: String) async throws -> MeetingStreamingPartialEngine {
        let plan = ManagedASRModelPlans.parakeetRealtimeEOU320()
        return try await ManagedASRModelDownloader.loadValidated(plan) { directory in
            let engine = ParakeetEOUMeetingPartialEngine(label: label)
            try await engine.loadModels(from: directory)
            return engine
        }
    }

    static func makeEngines(
        backend: MeetingLiveCaptionBackend,
        nemotronPromptId: Int32,
        appleSpeechLanguage: String
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
        case .appleSpeech:
            guard #available(macOS 26.0, *) else {
                throw AppleSpeechAnalyzerError.unavailable
            }
            let preparation = AppleSpeechAnalyzerTranscriber()
            let locale = try await preparation.prepare(
                requestedLocale: AppleSpeechLanguageOption.requestedLocale(for: appleSpeechLanguage)
            )
            let mic = AppleSpeechMeetingPartialEngine(locale: locale, label: "You")
            let system = AppleSpeechMeetingPartialEngine(locale: locale, label: "Others")
            do {
                try await mic.prepare()
                try await system.prepare()
                return (mic, system)
            } catch {
                await mic.shutdown()
                await system.shutdown()
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

enum MeetingStreamingPartialDeliveryMode: Sendable {
    case inline
    case asynchronous
}

protocol MeetingStreamingPartialEngine: AnyObject, Sendable {
    var partialDeliveryMode: MeetingStreamingPartialDeliveryMode { get }
    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async
    func process(samples: [Float]) async throws
    func restart(
        partialHandler: @escaping @Sendable (String) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) async throws
    func finish() async throws
    func shutdown() async
}

extension MeetingStreamingPartialEngine {
    var partialDeliveryMode: MeetingStreamingPartialDeliveryMode { .inline }
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {}
    func restart(
        partialHandler: @escaping @Sendable (String) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) async throws {
        await setPartialHandler(partialHandler)
        await setFailureHandler(failureHandler)
    }
    func finish() async throws {}
}

@available(macOS 26.0, *)
private actor AppleSpeechMeetingPartialEngine: MeetingStreamingPartialEngine {
    nonisolated let partialDeliveryMode = MeetingStreamingPartialDeliveryMode.asynchronous
    private static let maxBufferedInputs = MeetingStreamingPartialSession.maxQueuedChunks

    private let locale: Locale
    private let inputFormat: AVAudioFormat
    private let label: String
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<CMTime?, Error>?
    private var analysisMonitorTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Error>?
    private var accumulator = AppleSpeechLiveTranscriptAccumulator()
    private var partialHandler: (@Sendable (String) -> Void)?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var isFinished = false
    private var didReportFailure = false
    private var sessionGeneration: UInt64 = 0

    init(locale: Locale, label: String) {
        self.locale = locale
        inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        self.label = label
    }

    func prepare() async throws {
        guard analyzer == nil else { return }
        try await startSession()
        fputs("[meeting-partials] \(label) Apple Speech session ready\n", stderr)
    }

    func restart(
        partialHandler: @escaping @Sendable (String) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) async throws {
        await cancelCurrentSession()
        self.partialHandler = partialHandler
        self.failureHandler = failureHandler
        try await startSession()
        fputs("[meeting-partials] \(label) Apple Speech session restarted\n", stderr)
    }

    private func startSession() async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        try await analyzer.prepareToAnalyze(in: inputFormat)
        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.maxBufferedInputs)
        )
        sessionGeneration &+= 1
        let generation = sessionGeneration
        self.transcriber = transcriber
        self.analyzer = analyzer
        inputContinuation = continuation
        accumulator = AppleSpeechLiveTranscriptAccumulator()
        isFinished = false
        didReportFailure = false
        let analysisTask = Task {
            try await analyzer.analyzeSequence(inputStream)
        }
        self.analysisTask = analysisTask
        analysisMonitorTask = Task { [weak self] in
            do {
                _ = try await analysisTask.value
            } catch {
                guard !Task.isCancelled, let self else { return }
                await self.receiveFailure(error, generation: generation)
            }
        }
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled, let self else { return }
                    await self.receive(result, generation: generation)
                }
            } catch {
                guard !Task.isCancelled, let self else { throw error }
                await self.receiveFailure(error, generation: generation)
                throw error
            }
        }
    }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        partialHandler = handler
    }

    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {
        failureHandler = handler
    }

    func process(samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard !isFinished, let inputContinuation else {
            throw NSError(
                domain: "MeetingLiveCaptions",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Apple Speech live captions are not ready."]
            )
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.int16ChannelData?[0] else {
            throw NSError(
                domain: "MeetingLiveCaptions",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate a 16 kHz live-caption buffer."]
            )
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            let clamped = min(max(sample, -1), 1)
            channel[index] = Int16(clamped * Float(Int16.max))
        }
        if case .terminated = inputContinuation.yield(AnalyzerInput(buffer: buffer)) {
            throw NSError(
                domain: "MeetingLiveCaptions",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Apple Speech stopped accepting live audio."]
            )
        }
    }

    func finish() async throws {
        guard !isFinished else { return }
        isFinished = true
        inputContinuation?.finish()
        inputContinuation = nil

        if let lastSample = try await analysisTask?.value, let analyzer {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        try await resultsTask?.value
        partialHandler?(accumulator.text)
    }

    func shutdown() async {
        await cancelCurrentSession()
        partialHandler = nil
        failureHandler = nil
        fputs("[meeting-partials] \(label) Apple Speech session stopped\n", stderr)
    }

    private func cancelCurrentSession() async {
        sessionGeneration &+= 1
        inputContinuation?.finish()
        inputContinuation = nil
        analysisTask?.cancel()
        analysisMonitorTask?.cancel()
        resultsTask?.cancel()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        analysisTask = nil
        analysisMonitorTask = nil
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        accumulator = AppleSpeechLiveTranscriptAccumulator()
        isFinished = false
        didReportFailure = false
    }

    private func receive(_ result: SpeechTranscriber.Result, generation: UInt64) {
        guard generation == sessionGeneration else { return }
        accumulator.receive(
            text: String(result.text.characters),
            isFinal: result.isFinal,
            start: CMTimeGetSeconds(result.range.start),
            end: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
        )
        partialHandler?(accumulator.text)
    }

    private func receiveFailure(_ error: Error, generation: UInt64) {
        guard generation == sessionGeneration, !isFinished, !didReportFailure else { return }
        didReportFailure = true
        failureHandler?(error)
    }
}

/// Keeps only the text required by the live preview plus a small set of
/// progressive ranges. Durable timestamped segments are produced by the
/// meeting transcription pipeline, so the live adapter does not retain every
/// SpeechTranscriber result object for the lifetime of a meeting.
struct AppleSpeechLiveTranscriptAccumulator: Sendable {
    private struct Partial: Sendable {
        let rawText: String
        let start: Double
        let end: Double
    }

    static let maxProgressiveResults = 8

    private var finalizedText = ""
    private var progressiveResults: [Partial] = []

    var text: String {
        (finalizedText + progressiveResults.sorted(by: { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }).map(\.rawText).joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func receive(text rawText: String, isFinal: Bool, start: Double, end: Double) {
        let safeStart = start.isFinite ? max(0, start) : 0
        let safeEnd = end.isFinite ? max(safeStart, end) : safeStart
        progressiveResults.removeAll { existing in
            Self.overlaps(
                start: existing.start,
                end: existing.end,
                otherStart: safeStart,
                otherEnd: safeEnd
            )
        }

        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isFinal {
            finalizedText += rawText
            return
        }
        progressiveResults.append(Partial(rawText: rawText, start: safeStart, end: safeEnd))
        if progressiveResults.count > Self.maxProgressiveResults {
            progressiveResults.removeFirst(progressiveResults.count - Self.maxProgressiveResults)
        }
    }

    private static func overlaps(
        start: Double,
        end: Double,
        otherStart: Double,
        otherEnd: Double
    ) -> Bool {
        if start == end || otherStart == otherEnd {
            return start == otherStart
        }
        return start < otherEnd && otherStart < end
    }
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
    static let maxFrozenSegments = 12
    static let publicationIntervalNanoseconds: UInt64 = 250_000_000
    static let finishDrainTimeoutNanoseconds: UInt64 = 30_000_000_000

    private let engine: MeetingStreamingPartialEngine
    private let label: String

    private struct PendingSegment {
        let id: UUID
        let prefixLength: Int
        var frozenText: String?
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
        var isRestarting = false
        var didFail = false
        var pendingPublicationTail: String?
        var lastPublishedTail: String?
        var isPublicationScheduled = false
        var lifecycleRevision: UInt64 = 0
        var activeInferenceRevision: UInt64?
        var resumeRevision: UInt64?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(engine: MeetingStreamingPartialEngine, label: String) {
        self.engine = engine
        self.label = label
    }

    func connect() async {
        let revision = state.withLock { $0.lifecycleRevision }
        await engine.setPartialHandler { [weak self] text in
            self?.receiveEnginePartial(text, expectedRevision: revision)
        }
        await engine.setFailureHandler { [weak self] error in
            self?.receiveEngineFailure(error, expectedRevision: revision)
        }
    }

    /// Cheap append called from the existing meeting audio queue. Inference is
    /// single-flight and bounded so provisional captions cannot delay recording.
    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let shouldStartDrain = state.withLock { s -> Bool in
            guard !s.isStopped, !s.didFail, !s.isSuspended || s.isRestarting else { return false }
            s.sampleBuffer.append(contentsOf: samples)
            while s.sampleBuffer.count >= Self.feedSamples {
                s.chunkQueue.append(Array(s.sampleBuffer.prefix(Self.feedSamples)))
                s.sampleBuffer.removeFirst(Self.feedSamples)
            }
            if s.chunkQueue.count > Self.maxQueuedChunks {
                s.chunkQueue.removeFirst(s.chunkQueue.count - Self.maxQueuedChunks)
            }
            guard !s.isSuspended, !s.chunkQueue.isEmpty, !s.isDraining else { return false }
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
        let restartRevision: UInt64? = state.withLock { s in
            guard engine.partialDeliveryMode == .asynchronous else {
                s.pendingSegments.append(PendingSegment(
                    id: id,
                    prefixLength: s.engineText.count,
                    frozenText: nil
                ))
                return nil
            }
            let frozenText = currentEngineTail(for: s)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            s.pendingSegments.append(PendingSegment(
                id: id,
                prefixLength: 0,
                frozenText: frozenText.isEmpty ? nil : frozenText
            ))
            let frozenIndices = s.pendingSegments.indices.filter {
                s.pendingSegments[$0].frozenText != nil
            }
            if frozenIndices.count > Self.maxFrozenSegments {
                for index in frozenIndices.prefix(frozenIndices.count - Self.maxFrozenSegments) {
                    s.pendingSegments[index].frozenText = nil
                }
            }
            s.lifecycleRevision &+= 1
            s.isSuspended = true
            s.isRestarting = true
            s.resumeRevision = s.lifecycleRevision
            s.sampleBuffer.removeAll(keepingCapacity: true)
            s.chunkQueue.removeAll(keepingCapacity: true)
            s.engineText = ""
            s.committedPrefixLength = 0
            return s.lifecycleRevision
        }
        if let restartRevision {
            let tail = state.withLock { visibleTail(for: $0) }
            publishImmediately(tail, expectedRevision: restartRevision)
            Task.detached(priority: .utility) { [weak self] in
                await self?.resumeEngine(expectedRevision: restartRevision)
            }
        }
    }

    func pendingSegmentText(id: UUID) -> String? {
        state.withLock { s in
            guard !s.isStopped, !s.didFail,
                  let segmentIndex = s.pendingSegments.firstIndex(where: { $0.id == id }) else { return nil }
            let segment = s.pendingSegments[segmentIndex]
            if let frozenText = segment.frozenText {
                return frozenText
            }
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
            let canCommitWhileRestarting = engine.partialDeliveryMode == .asynchronous
                && s.isSuspended && s.isRestarting
            guard !s.isStopped, (!s.isSuspended || canCommitWhileRestarting), !s.didFail else { return nil }
            guard let segmentIndex = s.pendingSegments.firstIndex(where: { $0.id == id }) else { return nil }
            s.pendingSegments[segmentIndex].isCommitted = true
            var didAdvance = false
            while let first = s.pendingSegments.first, first.isCommitted {
                if engine.partialDeliveryMode == .inline {
                    s.committedPrefixLength = max(
                        s.committedPrefixLength,
                        min(first.prefixLength, s.engineText.count)
                    )
                }
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
    /// Buffered audio is dropped and the current engine prefix is hidden.
    /// Resume restarts engines that deliver results asynchronously before new
    /// audio is accepted, while cache-aware inline engines remain warm.
    func suspend() {
        state.withLock { s in
            s.isSuspended = true
            s.isRestarting = false
            s.lifecycleRevision &+= 1
            s.resumeRevision = nil
            s.sampleBuffer.removeAll(keepingCapacity: true)
            s.chunkQueue.removeAll(keepingCapacity: true)
            s.committedPrefixLength = s.engineText.count
            s.pendingSegments.removeAll(keepingCapacity: true)
        }
        publishImmediately("")
    }

    func resume() {
        if engine.partialDeliveryMode == .inline {
            state.withLock { s in
                guard !s.isStopped, !s.didFail, s.isSuspended else { return }
                s.isSuspended = false
            }
            return
        }
        let revision: UInt64? = state.withLock { s in
            guard !s.isStopped, !s.didFail, s.isSuspended, s.resumeRevision == nil else { return nil }
            s.isRestarting = true
            s.resumeRevision = s.lifecycleRevision
            return s.lifecycleRevision
        }
        guard let revision else { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.resumeEngine(expectedRevision: revision)
        }
    }

    /// A rebuilt capture source starts a new live-ASR lifecycle. Existing
    /// provisional text is cleared because audio before the discontinuity has
    /// already entered the durable chunk pipeline.
    func resetAfterSourceRestart() {
        suspend()
        resume()
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
            s.resumeRevision = nil
            s.isRestarting = false
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

    private func resumeEngine(expectedRevision: UInt64) async {
        do {
            try await engine.restart(
                partialHandler: { [weak self] text in
                    self?.receiveEnginePartial(text, expectedRevision: expectedRevision)
                },
                failureHandler: { [weak self] error in
                    self?.receiveEngineFailure(error, expectedRevision: expectedRevision)
                }
            )
            guard state.withLock({ s in
                !s.isStopped && !s.didFail && s.isSuspended
                    && s.lifecycleRevision == expectedRevision
                    && s.resumeRevision == expectedRevision
            }) else {
                if state.withLock({ $0.isStopped || $0.didFail }) {
                    await engine.shutdown()
                }
                return
            }
            let activation = state.withLock { s -> (activated: Bool, shouldDrain: Bool) in
                guard !s.isStopped, !s.didFail, s.isSuspended,
                      s.lifecycleRevision == expectedRevision,
                      s.resumeRevision == expectedRevision else { return (false, false) }
                s.resumeRevision = nil
                s.isSuspended = false
                s.isRestarting = false
                guard !s.chunkQueue.isEmpty, !s.isDraining else { return (true, false) }
                s.isDraining = true
                return (true, true)
            }
            if activation.shouldDrain {
                Task.detached(priority: .utility) { [weak self] in
                    await self?.drain()
                }
            }
            if !activation.activated, state.withLock({ $0.isStopped || $0.didFail }) {
                await engine.shutdown()
            }
        } catch {
            let isCurrent = state.withLock { s in
                s.lifecycleRevision == expectedRevision && s.resumeRevision == expectedRevision
            }
            if isCurrent {
                goDormant(error: error)
            }
        }
    }

    private func receiveEngineFailure(_ error: Error, expectedRevision: UInt64) {
        let isCurrent = state.withLock { s in
            !s.isStopped && !s.didFail && (!s.isSuspended || s.isRestarting)
                && expectedRevision == s.lifecycleRevision
        }
        if isCurrent {
            goDormant(error: error)
        }
    }

    private func receiveEnginePartial(_ text: String, expectedRevision: UInt64) {
        let filteredText = TranscriptionEngineArtifactsFilter.apply(text)
        let tail: String? = state.withLock { s in
            guard !s.isStopped, !s.isSuspended, !s.didFail,
                  (engine.partialDeliveryMode == .asynchronous
                    ? expectedRevision == s.lifecycleRevision
                    : s.activeInferenceRevision == s.lifecycleRevision) else { return nil }
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
            s.resumeRevision = nil
            s.isRestarting = false
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
        if engine.partialDeliveryMode == .asynchronous {
            let frozenText = state.pendingSegments
                .filter { !$0.isCommitted }
                .compactMap(\.frozenText)
                .joined(separator: " ")
            return [frozenText, state.engineText]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return currentEngineTail(for: state)
    }

    private func currentEngineTail(for state: State) -> String {
        let dropCount = min(state.committedPrefixLength, state.engineText.count)
        return String(state.engineText.dropFirst(dropCount))
    }
}
