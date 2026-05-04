import FluidAudio
import ApplicationServices
import Foundation
import MuesliCore
import os

final class MeetingChunkCollector {
    private struct State {
        var tasks: [Task<[SpeechSegment], Never>] = []
        var isClosed = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func add(_ task: Task<[SpeechSegment], Never>) -> Bool {
        lock.withLock { state in
            guard !state.isClosed else { return false }
            state.tasks.append(task)
            return true
        }
    }

    func closeAndDrainSortedSegments() async -> [SpeechSegment] {
        let tasksToAwait = lock.withLock { state in
            state.isClosed = true
            let pendingTasks = state.tasks
            state.tasks.removeAll()
            return pendingTasks
        }

        var segments: [SpeechSegment] = []
        for task in tasksToAwait {
            segments.append(contentsOf: await task.value)
        }

        return segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock { state in
            state.isClosed = true
            let pendingTasks = state.tasks
            state.tasks.removeAll()
            return pendingTasks
        }

        tasksToCancel.forEach { $0.cancel() }
    }
}

struct MeetingSessionResult {
    let title: String
    let originalTitle: String
    let calendarEventID: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let retainedRecordingURL: URL?
    let retainedRecordingError: Error?
    let systemRecordingURL: URL?
    let templateSnapshot: MeetingTemplateSnapshot
}

enum MeetingProcessingStage {
    case transcribingAudio
    case cleaningAudio
    case generatingTitle
    case summarizingNotes
}

private enum MeetingTranscriptRecoveryResult {
    case none
    case append([SpeechSegment])
    case replace([SpeechSegment])
}

final class MeetingSession {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingSession")

    private let title: String
    private let calendarEventID: String?
    private let backend: BackendOption
    private let runtime: RuntimePaths
    private let config: AppConfig
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let systemAudioRecorder: SystemAudioCapturing
    private let fullSessionMicRecorder = MicrophoneRecorder()
    private let neuralAec = MeetingNeuralAec()

    /// Streaming mic recorder with real-time buffer access (AVAudioEngine)
    private var streamingMicRecorder = StreamingMicRecorder()
    private var rawMicChunkRecorder: PCMChunkRecorder?
    private var retainedRecordingWriter: MeetingRecordingWriter?
    private var retainedRecordingWriterError: Error?
    /// VAD controller for speech-boundary chunk rotation
    private var vadController: StreamingVadController?
    private var systemVadController: StreamingVadController?
    private let micChunkCollector = MeetingChunkCollector()
    private let systemChunkCollector = MeetingChunkCollector()
    private let micChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let systemChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let chunkRotationQueue = DispatchQueue(label: "MuesliNative.MeetingSession.chunkRotation")
    private let pausedDisplayLock = OSAllocatedUnfairLock(initialState: false)
    private var chunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkRecorder: PCMChunkRecorder?
    var onProgress: ((MeetingProcessingStage) -> Void)?
    var manualNotesProvider: (() async -> String?)?
    var liveTitleProvider: (() async -> String?)?
    private let screenContextCollector = MeetingScreenContextCollector()

    /// Current mic power level for waveform visualization.
    func currentPower() -> Float {
        if pausedDisplayLock.withLock({ $0 }) {
            return -160
        }
        return streamingMicRecorder.currentPower()
    }

    private(set) var startTime: Date?
    private(set) var isRecording = false
    private(set) var isPaused = false

    private func setPausedStateOnQueue(_ paused: Bool) {
        isPaused = paused
        pausedDisplayLock.withLock { $0 = paused }
    }

    init(
        title: String,
        calendarEventID: String?,
        backend: BackendOption,
        runtime: RuntimePaths,
        config: AppConfig,
        transcriptionCoordinator: TranscriptionCoordinator
    ) {
        self.title = title
        self.calendarEventID = calendarEventID
        self.backend = backend
        self.runtime = runtime
        self.config = config
        self.transcriptionCoordinator = transcriptionCoordinator
        if config.useCoreAudioTap {
            self.systemAudioRecorder = CoreAudioSystemRecorder()
        } else {
            self.systemAudioRecorder = SystemAudioRecorder()
        }
    }

    func start() async throws {
        let vadManager = await transcriptionCoordinator.getVadManager()
        let now = Date()

        // AEC must be loaded before audio pipeline starts (streaming mode)
        await neuralAec.preload()

        chunkRotationQueue.sync {
            startTime = now
            chunkTimingTracker.start()
            systemChunkTimingTracker.start()
            isRecording = true
            setPausedStateOnQueue(false)
        }

        do {
            try prepareRealtimeAudioPipeline(vadManager: vadManager)
            try fullSessionMicRecorder.prepare()
            try streamingMicRecorder.prepare()
            setupRetainedRecordingWriterIfNeeded()
            try fullSessionMicRecorder.start()
            try streamingMicRecorder.start()
            try await systemAudioRecorder.start()
        } catch {
            vadController?.stop()
            vadController = nil
            systemVadController?.stop()
            systemVadController = nil
            streamingMicRecorder.onAudioBuffer = nil
            streamingMicRecorder.onPCMSamples = nil
            systemAudioRecorder.onPCMSamples = nil
            fullSessionMicRecorder.cancel()
            retainedRecordingWriter?.cancel()
            retainedRecordingWriter = nil
            rawMicChunkRecorder?.cancel()
            rawMicChunkRecorder = nil
            systemChunkRecorder?.cancel()
            systemChunkRecorder = nil
            chunkRotationQueue.sync {
                isRecording = false
                setPausedStateOnQueue(false)
                startTime = nil
                chunkTimingTracker.discard()
                systemChunkTimingTracker.discard()
            }
            streamingMicRecorder.cancel()
            if let url = systemAudioRecorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            systemChunkCollector.cancelAll()
            throw error
        }
        if vadController != nil {
            fputs("[meeting] started with VAD-driven chunk rotation\n", stderr)
        } else {
            fputs("[meeting] VAD not available, using max-duration fallback only\n", stderr)
        }
        if config.enableScreenContext && CGPreflightScreenCaptureAccess() {
            // OCR screenshots are safe when using CoreAudio tap (no SCStream conflict)
            await screenContextCollector.startPeriodicCapture(useOCR: config.useCoreAudioTap)
        }
    }

    func pause() {
        let shouldPause = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, !isPaused else { return false }
            appendFlushedStreamingMicOnQueue()
            rotateChunkOnQueue()
            rotateSystemChunkOnQueue()
            retainedRecordingWriter?.markPauseBoundary()
            neuralAec.resetForStreaming()
            setPausedStateOnQueue(true)
            return true
        }
        guard shouldPause else { return }

        fullSessionMicRecorder.pause()
        streamingMicRecorder.pause()
        systemAudioRecorder.pause()
        Task { await screenContextCollector.setPaused(true) }
        fputs("[meeting] recording paused\n", stderr)
    }

    func resume() {
        let shouldResume = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, isPaused else { return false }
            setPausedStateOnQueue(false)
            return true
        }
        guard shouldResume else { return }

        fullSessionMicRecorder.resume()
        streamingMicRecorder.resume()
        systemAudioRecorder.resume()
        Task { await screenContextCollector.setPaused(false) }
        fputs("[meeting] recording resumed\n", stderr)
    }

    /// Abandon the recording — stop everything, delete temp files, don't transcribe.
    func discard() {
        Task { await screenContextCollector.stopAndDrain() }
        let (rawRecorder, systemRecorder) = chunkRotationQueue.sync { () -> (PCMChunkRecorder?, PCMChunkRecorder?) in
            isRecording = false
            setPausedStateOnQueue(false)
            chunkTimingTracker.discard()
            systemChunkTimingTracker.discard()
            let rawRecorder = rawMicChunkRecorder
            let systemRecorder = systemChunkRecorder
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            return (rawRecorder, systemRecorder)
        }
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        retainedRecordingWriter?.cancel()
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil
        rawRecorder?.cancel()
        systemRecorder?.cancel()
        fullSessionMicRecorder.cancel()
        streamingMicRecorder.onAudioBuffer = nil
        streamingMicRecorder.onPCMSamples = nil
        streamingMicRecorder.cancel()
        systemAudioRecorder.onPCMSamples = nil
        if let url = systemAudioRecorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        micChunkCollector.cancelAll()
        systemChunkCollector.cancelAll()
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop() async throws -> MeetingSessionResult {
        onProgress?(.transcribingAudio)
        let endTime = Date()
        var micSegments: [SpeechSegment] = []
        var systemSegments: [SpeechSegment] = []

        // Stop VAD controller
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        streamingMicRecorder.onAudioBuffer = nil
        streamingMicRecorder.onPCMSamples = nil
        systemAudioRecorder.onPCMSamples = nil
        let (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL) = chunkRotationQueue.sync { () -> (Date, MeetingChunkTimingSnapshot?, URL?, MeetingChunkTimingSnapshot?, URL?) in
            isRecording = false
            setPausedStateOnQueue(false)

            // Flush partial AEC frame before stopping chunk recorder
            appendFlushedStreamingMicOnQueue()

            let meetingStart = self.startTime ?? Date()
            let lastRawMicURL = rawMicChunkRecorder?.stop()
            let lastSystemChunkURL = systemChunkRecorder?.stop()
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            let lastChunkTiming = chunkTimingTracker.finish()
            let lastSystemChunkTiming = systemChunkTimingTracker.finish()
            return (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL)
        }
        let rawStreamingMicURL = streamingMicRecorder.stop()
        let fullSessionMicURL = fullSessionMicRecorder.stop()
        let retainedRecordingURL = retainedRecordingWriter?.stop()
        retainedRecordingWriter = nil
        defer {
            if let rawStreamingMicURL {
                try? FileManager.default.removeItem(at: rawStreamingMicURL)
            }
            if let fullSessionMicURL {
                try? FileManager.default.removeItem(at: fullSessionMicURL)
            }
        }

        // Stop system audio
        let systemAudioURL = systemAudioRecorder.stop()

        // Transcribe last mic chunk
        let finalMicSegments = await transcribeMicChunk(
            rawURL: lastRawMicURL,
            chunkTiming: lastChunkTiming,
            isFinalChunk: true
        )
        micSegments.append(contentsOf: finalMicSegments)

        if let lastSystemChunkURL {
            let chunkOffset = lastSystemChunkTiming?.startTimeSeconds ?? 0
            let chunkDuration = lastSystemChunkTiming?.durationSeconds ?? 0
            fputs("[meeting] transcribing final system chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
            do {
                let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                    at: lastSystemChunkURL,
                    backend: backend,
                    cohereLanguage: config.resolvedCohereLanguage
                )
                let normalizedSegments = normalizeSystemTranscription(
                    result: result,
                    startTime: chunkOffset,
                    endTime: chunkOffset + max(chunkDuration, 0.1)
                )
                if normalizedSegments.isEmpty {
                    systemChunkHealthTracker.noteEmptyChunk()
                } else {
                    systemChunkHealthTracker.noteSuccessfulChunk()
                }
                systemSegments.append(contentsOf: normalizedSegments)
            } catch {
                systemChunkHealthTracker.noteFailedChunk()
                fputs("[meeting] final system chunk transcription failed: \(error)\n", stderr)
            }
            try? FileManager.default.removeItem(at: lastSystemChunkURL)
        }

        var diarizationSegments: [TimedSpeakerSegment]?
        if let systemAudioURL {
            // Run speaker diarization on system audio (batch post-processing)
            if let diarizationResult = try? await transcriptionCoordinator.diarizeSystemAudio(at: systemAudioURL) {
                diarizationSegments = diarizationResult.segments
            }
        }

        micSegments.append(contentsOf: await micChunkCollector.closeAndDrainSortedSegments())
        micSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        systemSegments.append(contentsOf: await systemChunkCollector.closeAndDrainSortedSegments())
        systemSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        if let fullSessionMicURL {
            let micRecovery = await repairMicSegmentsIfNeeded(
                existingMicSegments: micSegments,
                fullSessionMicURL: fullSessionMicURL,
                meetingStart: meetingStart,
                endTime: endTime
            )
            switch micRecovery {
            case .none:
                break
            case .append(let repairedMicSegments):
                micSegments.append(contentsOf: repairedMicSegments)
                micSegments.sort { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            case .replace(let fallbackMicSegments):
                micSegments = fallbackMicSegments.sorted { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            }
        }

        if let systemAudioURL {
            let systemRecovery = await repairSystemSegmentsIfNeeded(
                existingSystemSegments: systemSegments,
                systemAudioURL: systemAudioURL,
                meetingStart: meetingStart,
                endTime: endTime
            )
            switch systemRecovery {
            case .none:
                break
            case .append(let repairedSystemSegments):
                systemSegments.append(contentsOf: repairedSystemSegments)
                systemSegments.sort { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            case .replace(let fallbackSystemSegments):
                systemSegments = fallbackSystemSegments.sorted { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            }
        }

        fputs("[meeting] \(micSegments.count) mic chunks transcribed during meeting\n", stderr)
        fputs("[meeting] \(systemSegments.count) system chunks transcribed during meeting\n", stderr)

        // Speaker-embedding bleed detection: compare mic chunk embeddings against
        // system speaker embeddings from diarization. Drop mic segments that match
        // a system speaker (bleed) and keep segments that don't match (user speech).
        if let diarizationSegments, !diarizationSegments.isEmpty, let fullSessionMicURL {
            if let diarizerManager = await transcriptionCoordinator.getDiarizerManager() {
                do {
                    let micSamples = try AudioConverter().resampleAudioFile(fullSessionMicURL)
                    let centroids = MeetingBleedDetector.systemSpeakerCentroids(from: diarizationSegments)
                    if !centroids.isEmpty {
                        let bleedResult = MeetingBleedDetector.filterBleed(
                            micSegments: micSegments,
                            fullMicSamples: micSamples,
                            systemSpeakerCentroids: centroids,
                            diarizerManager: diarizerManager
                        )
                        fputs("[meeting] bleed detection: kept \(bleedResult.keptSegments.count), dropped \(bleedResult.droppedCount) mic segments\n", stderr)
                        micSegments = bleedResult.keptSegments
                    }
                } catch {
                    fputs("[meeting] bleed detection failed, keeping all mic segments: \(error)\n", stderr)
                }
            }
        }

        let reconciledTranscriptInputs = TranscriptReconciler.reconcile(
            micTurns: micSegments,
            systemSegments: systemSegments,
            diarizationSegments: diarizationSegments
        )
        let protectedTranscriptInputs: ReconciledTranscriptInputs
        if let fullSessionMicURL {
            protectedTranscriptInputs = await protectLocalMicSpeechAfterReconciliation(
                originalMicSegments: micSegments,
                reconciledTranscriptInputs: reconciledTranscriptInputs,
                fullSessionMicURL: fullSessionMicURL
            )
        } else {
            protectedTranscriptInputs = reconciledTranscriptInputs
        }

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: protectedTranscriptInputs.micSegments,
            systemSegments: protectedTranscriptInputs.systemSegments,
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            meetingStart: meetingStart
        )

        let generatedTitle: String
        onProgress?(.generatingTitle)
        if let liveTitle = await userEditedLiveTitle() {
            generatedTitle = liveTitle
        } else if let calendarTitle = Self.calendarTitleCandidate(
            originalTitle: title,
            calendarEventID: calendarEventID
        ) {
            generatedTitle = calendarTitle
        } else if let autoTitle = await MeetingSummaryClient.generateTitle(transcript: rawTranscript, config: config),
           !autoTitle.isEmpty {
            generatedTitle = autoTitle
            fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
        } else {
            generatedTitle = title
        }

        let templateSnapshot = MeetingTemplates.resolveSnapshot(
            id: config.defaultMeetingTemplateID,
            customTemplates: config.customMeetingTemplates
        )
        let visualContext = await screenContextCollector.stopAndDrain()
        Self.logger.info("visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(self.config.useCoreAudioTap)")
        fputs("[meeting] visual context drained chars=\(visualContext.count) includedInPrompt=\(!visualContext.isEmpty) useOCR=\(config.useCoreAudioTap)\n", stderr)
        onProgress?(.summarizingNotes)
        let manualNotes = await manualNotesProvider?()
        let formattedNotes: String
        do {
            formattedNotes = try await MeetingSummaryClient.summarize(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                config: config,
                template: templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: manualNotes,
                visualContext: visualContext.isEmpty ? nil : visualContext
            )
        } catch {
            fputs("[meeting] summary generation failed: \(error.localizedDescription)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: rawTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: manualNotes
            )
        }

        return MeetingSessionResult(
            title: generatedTitle,
            originalTitle: title,
            calendarEventID: calendarEventID,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingWriterError,
            systemRecordingURL: systemAudioURL,
            templateSnapshot: templateSnapshot
        )
    }

    static func calendarTitleCandidate(originalTitle: String, calendarEventID: String?) -> String? {
        guard calendarEventID != nil else { return nil }
        guard !originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return originalTitle
    }

    private func userEditedLiveTitle() async -> String? {
        guard let candidate = await liveTitleProvider?() else { return nil }
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return nil }
        guard trimmedCandidate != trimmedOriginal else { return nil }
        return trimmedCandidate
    }

    private func appendFlushedStreamingMicOnQueue() {
        let flushed = neuralAec.flushStreamingMic()
        guard !flushed.isEmpty else { return }
        let flushedInt16 = flushed.map { sample -> Int16 in
            Int16(max(-1.0, min(1.0, sample)) * 32767)
        }
        rawMicChunkRecorder?.append(flushedInt16)
    }

    /// Called by VAD on speech boundaries or max-duration fallback.
    /// Rotates the streaming mic file and sends the completed chunk for transcription.
    private func rotateChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateChunkOnQueue()
        }
    }

    private func rotateChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        guard let chunkTiming = chunkTimingTracker.rotate() else {
            return
        }
        let rawChunkURL = rawMicChunkRecorder?.rotateFile()

        guard rawChunkURL != nil else {
            return
        }

        // Transcribe the completed chunk async
        let chunkOffset = chunkTiming.startTimeSeconds

        fputs("[meeting] rotating raw mic chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)

        let task = Task { [weak self] () -> [SpeechSegment] in
            guard let self else { return [] }
            if Task.isCancelled {
                self.cleanupTemporaryChunkURLs(rawChunkURL)
                return []
            }
            let segments = await self.transcribeMicChunk(
                rawURL: rawChunkURL,
                chunkTiming: chunkTiming,
                isFinalChunk: false
            )
            return segments
        }
        if !micChunkCollector.add(task) {
            task.cancel()
            cleanupTemporaryChunkURLs(rawChunkURL)
        }
    }

    private func rotateSystemChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateSystemChunkOnQueue()
        }
    }

    private func rotateSystemChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        guard let chunkURL = systemChunkRecorder?.rotateFile(),
              let chunkTiming = systemChunkTimingTracker.rotate() else {
            return
        }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        let backend = self.backend

        fputs("[meeting] rotating system chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)

        let task = Task { [weak self] () -> [SpeechSegment] in
            defer {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            guard let self else { return [] }
            do {
                if Task.isCancelled {
                    return []
                }
                let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(
                    at: chunkURL,
                    backend: backend,
                    cohereLanguage: config.resolvedCohereLanguage
                )
                if !result.text.isEmpty {
                    fputs("[meeting] system chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                    let normalizedSegments = self.normalizeSystemTranscription(
                        result: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                    if normalizedSegments.isEmpty {
                        self.systemChunkHealthTracker.noteEmptyChunk()
                    } else {
                        self.systemChunkHealthTracker.noteSuccessfulChunk()
                    }
                    return normalizedSegments
                }
                self.systemChunkHealthTracker.noteEmptyChunk()
            } catch {
                self.systemChunkHealthTracker.noteFailedChunk()
                fputs("[meeting] system chunk transcription failed: \(error)\n", stderr)
            }
            return []
        }
        if !systemChunkCollector.add(task) {
            task.cancel()
        }
    }

    private func setupRetainedRecordingWriterIfNeeded() {
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil

        guard config.meetingRecordingSavePolicy != .never else { return }

        do {
            retainedRecordingWriter = try MeetingRecordingWriter()
        } catch {
            retainedRecordingWriterError = error
            fputs("[meeting] failed to prepare retained recording writer: \(error)\n", stderr)
        }
    }

    private func prepareRealtimeAudioPipeline(vadManager: VadManager?) throws {
        rawMicChunkRecorder = try PCMChunkRecorder(directoryName: "muesli-meeting-mic-chunks")
        systemChunkRecorder = try PCMChunkRecorder(directoryName: "muesli-meeting-system-chunks")
        configureRealtimeAudioCallbacks(vadManager: vadManager)
    }

    private func configureRealtimeAudioCallbacks(vadManager: VadManager?) {
        if let vadManager {
            let controller = StreamingVadController(vadManager: vadManager)
            controller.onChunkBoundary = { [weak self] in
                self?.rotateChunk()
            }
            controller.start()
            vadController = controller

            let systemController = StreamingVadController(vadManager: vadManager)
            systemController.onChunkBoundary = { [weak self] in
                self?.rotateSystemChunk()
            }
            systemController.start()
            systemVadController = systemController
        } else {
            vadController = nil
            systemVadController = nil
        }
        neuralAec.resetForStreaming()
        streamingMicRecorder.onAudioBuffer = nil

        streamingMicRecorder.onPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeMicSamples(samples)
        }
        systemAudioRecorder.onPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeSystemSamples(samples)
        }
    }

    private func enqueueRealtimeMicSamples(_ rawSamples: [Int16]) {
        guard !rawSamples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            self.retainedRecordingWriter?.appendMic(rawSamples)
            self.chunkTimingTracker.append(sampleCount: rawSamples.count)

            let floatSamples = rawSamples.map { Float($0) / 32767.0 }

            // VAD always sees raw audio for reliable speech boundary detection
            if let vadController = self.vadController {
                vadController.processAudio(floatSamples)
            }

            // AEC: clean mic using position-aligned system reference
            let cleanedFloat = self.neuralAec.processStreamingMic(floatSamples)
            if !cleanedFloat.isEmpty {
                let cleanedInt16 = cleanedFloat.map { sample -> Int16 in
                    Int16(max(-1.0, min(1.0, sample)) * 32767)
                }
                self.rawMicChunkRecorder?.append(cleanedInt16)
            }
        }
    }

    private func enqueueRealtimeSystemSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self, self.isRecording, !self.isPaused else { return }

            self.retainedRecordingWriter?.appendSystem(samples)
            self.systemChunkRecorder?.append(samples)
            self.systemChunkTimingTracker.append(sampleCount: samples.count)

            let floatSamples = samples.map { Float($0) / 32767.0 }
            self.neuralAec.feedSystemSamples(floatSamples)

            if let systemVadController = self.systemVadController {
                systemVadController.processAudio(floatSamples)
            }
        }
    }

    private func transcribeMicChunk(
        rawURL: URL?,
        chunkTiming: MeetingChunkTimingSnapshot?,
        isFinalChunk: Bool
    ) async -> [SpeechSegment] {
        defer {
            cleanupTemporaryChunkURLs(rawURL)
        }

        guard let chunkTiming, let rawURL else { return [] }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        let logPrefix = isFinalChunk ? "[meeting] transcribing final mic chunk" : "[meeting] transcribing mic chunk"

        return await transcribeMicChunk(
            at: rawURL,
            chunkOffset: chunkOffset,
            chunkDuration: chunkDuration,
            logPrefix: logPrefix
        ) ?? []
    }

    private func transcribeMicChunk(
        at url: URL,
        chunkOffset: TimeInterval,
        chunkDuration: TimeInterval,
        logPrefix: String
    ) async -> [SpeechSegment]? {
        fputs("\(logPrefix) (offset=\(String(format: "%.0f", chunkOffset))s, source=raw)\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                at: url,
                backend: backend,
                cohereLanguage: config.resolvedCohereLanguage
            )
            if !result.text.isEmpty {
                fputs("[meeting] mic chunk transcribed (raw): \"\(String(result.text.prefix(60)))...\"\n", stderr)
                let normalizedSegments = MicTurnNormalizer.normalize(
                    result: result,
                    startTime: chunkOffset,
                    endTime: chunkOffset + max(chunkDuration, 0.1)
                )
                if normalizedSegments.isEmpty {
                    micChunkHealthTracker.noteEmptyChunk()
                } else {
                    micChunkHealthTracker.noteSuccessfulChunk()
                }
                return normalizedSegments
            }
            micChunkHealthTracker.noteEmptyChunk()
            return []
        } catch {
            micChunkHealthTracker.noteFailedChunk()
            fputs("[meeting] mic chunk transcription failed (raw): \(error)\n", stderr)
            return nil
        }
    }

    private func cleanupTemporaryChunkURLs(_ urls: URL?...) {
        urls.compactMap { $0 }.forEach { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func normalizeSystemTranscription(
        result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        SystemTurnNormalizer.normalize(
            result: result,
            startTime: startTime,
            endTime: endTime
        )
    }

    private func durationSeconds(from start: Date, to end: Date) -> Double {
        max(end.timeIntervalSince(start), 0)
    }

    private func protectLocalMicSpeechAfterReconciliation(
        originalMicSegments: [SpeechSegment],
        reconciledTranscriptInputs: ReconciledTranscriptInputs,
        fullSessionMicURL: URL
    ) async -> ReconciledTranscriptInputs {
        guard !originalMicSegments.isEmpty else { return reconciledTranscriptInputs }
        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            return reconciledTranscriptInputs
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(fullSessionMicURL)
            let offlineSpeechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            let decision = MeetingLocalSpeechGuard.decide(
                originalMicSegments: originalMicSegments,
                reconciledMicSegments: reconciledTranscriptInputs.micSegments,
                offlineSpeechSegments: offlineSpeechSegments,
                chunkHealth: micChunkHealthTracker.snapshot()
            )

            if decision.revertedToOriginal {
                fputs(
                    "[meeting] restored original mic turns after reconciliation " +
                    "(coverage \(String(format: "%.2f", decision.reconciledCoverageRatio)) -> " +
                    "\(String(format: "%.2f", decision.originalCoverageRatio)); " +
                    "\(decision.reason))\n",
                    stderr
                )
            }

            return ReconciledTranscriptInputs(
                micSegments: decision.preferredMicSegments,
                systemSegments: reconciledTranscriptInputs.systemSegments,
                diarizationSegments: reconciledTranscriptInputs.diarizationSegments
            )
        } catch {
            fputs("[meeting] failed to validate reconciled mic coverage: \(error)\n", stderr)
            return reconciledTranscriptInputs
        }
    }

    private func repairMicSegmentsIfNeeded(
        existingMicSegments: [SpeechSegment],
        fullSessionMicURL: URL,
        meetingStart: Date,
        endTime: Date
    ) async -> MeetingTranscriptRecoveryResult {
        let totalDuration = durationSeconds(from: meetingStart, to: endTime)

        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            if existingMicSegments.isEmpty {
                return .replace(await fallbackToFullSessionMicTranscription(
                    fullSessionMicURL: fullSessionMicURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(fullSessionMicURL)
            let speechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            let health = MeetingTranscriptHealthMonitor.evaluate(
                existingSegments: existingMicSegments,
                offlineSpeechSegments: speechSegments,
                chunkHealth: micChunkHealthTracker.snapshot()
            )
            fputs("\(health.summaryLine)\n", stderr)

            switch health.action {
            case .accept:
                return .none
            case .fullFallback(let reason):
                fputs("[meeting] transcript health triggered full mic fallback: \(reason)\n", stderr)
                return .replace(await fallbackToFullSessionMicTranscription(
                    fullSessionMicURL: fullSessionMicURL,
                    meetingDuration: totalDuration
                ))
            case .selectiveRepair(let repairSegments):
                guard !repairSegments.isEmpty else { return .none }

                fputs("[meeting] repairing \(repairSegments.count) uncovered mic speech regions\n", stderr)

                var repairedSegments: [SpeechSegment] = []
                for speechSegment in repairSegments {
                    let startSample = max(0, speechSegment.startSample(sampleRate: VadManager.sampleRate))
                    let endSample = min(samples.count, speechSegment.endSample(sampleRate: VadManager.sampleRate))
                    guard endSample > startSample else { continue }

                    let segmentURL = try MeetingMicRepairPlanner.writeTemporaryWAV(
                        samples: Array(samples[startSample..<endSample])
                    )
                    defer { try? FileManager.default.removeItem(at: segmentURL) }

                    let result = try await transcriptionCoordinator.transcribeMeeting(
                        at: segmentURL,
                        backend: backend,
                        cohereLanguage: config.resolvedCohereLanguage
                    )
                    repairedSegments.append(contentsOf: MicTurnNormalizer.normalize(
                        result: result,
                        startTime: speechSegment.startTime,
                        endTime: speechSegment.endTime
                    ))
                }
                return repairedSegments.isEmpty ? .none : .append(repairedSegments)
            }
        } catch {
            fputs("[meeting] mic repair pass failed: \(error)\n", stderr)
            if existingMicSegments.isEmpty {
                return .replace(await fallbackToFullSessionMicTranscription(
                    fullSessionMicURL: fullSessionMicURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }
    }

    private func repairSystemSegmentsIfNeeded(
        existingSystemSegments: [SpeechSegment],
        systemAudioURL: URL,
        meetingStart: Date,
        endTime: Date
    ) async -> MeetingTranscriptRecoveryResult {
        let totalDuration = durationSeconds(from: meetingStart, to: endTime)

        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }

        do {
            let samples = try AudioConverter().resampleAudioFile(systemAudioURL)
            let speechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            let health = MeetingTranscriptHealthMonitor.evaluate(
                existingSegments: existingSystemSegments,
                offlineSpeechSegments: speechSegments,
                chunkHealth: systemChunkHealthTracker.snapshot()
            )
            fputs("[meeting] system \(health.summaryLine.dropFirst("[meeting] ".count))\n", stderr)

            switch health.action {
            case .accept:
                return .none
            case .fullFallback(let reason):
                fputs("[meeting] transcript health triggered full system fallback: \(reason)\n", stderr)
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            case .selectiveRepair(let repairSegments):
                guard !repairSegments.isEmpty else { return .none }

                fputs("[meeting] repairing \(repairSegments.count) uncovered system speech regions\n", stderr)

                var repairedSegments: [SpeechSegment] = []
                for speechSegment in repairSegments {
                    let startSample = max(0, speechSegment.startSample(sampleRate: VadManager.sampleRate))
                    let endSample = min(samples.count, speechSegment.endSample(sampleRate: VadManager.sampleRate))
                    guard endSample > startSample else { continue }

                    let segmentURL = try MeetingMicRepairPlanner.writeTemporaryWAV(
                        samples: Array(samples[startSample..<endSample])
                    )
                    defer { try? FileManager.default.removeItem(at: segmentURL) }

                    let result = try await transcriptionCoordinator.transcribeMeeting(
                        at: segmentURL,
                        backend: backend,
                        cohereLanguage: config.resolvedCohereLanguage
                    )
                    repairedSegments.append(contentsOf: normalizeSystemTranscription(
                        result: result,
                        startTime: speechSegment.startTime,
                        endTime: speechSegment.endTime
                    ))
                }
                return repairedSegments.isEmpty ? .none : .append(repairedSegments)
            }
        } catch {
            fputs("[meeting] system repair pass failed: \(error)\n", stderr)
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration
                ))
            }
            return .none
        }
    }

    private func fallbackToFullSessionMicTranscription(
        fullSessionMicURL: URL,
        meetingDuration: Double
    ) async -> [SpeechSegment] {
        fputs("[meeting] no mic chunks survived, falling back to full-session mic transcription\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeeting(
                at: fullSessionMicURL,
                backend: backend,
                cohereLanguage: config.resolvedCohereLanguage
            )
            return MicTurnNormalizer.normalize(
                result: result,
                startTime: 0,
                endTime: meetingDuration
            )
        } catch {
            fputs("[meeting] full-session mic fallback transcription failed: \(error)\n", stderr)
            return []
        }
    }

    private func fallbackToFullSessionSystemTranscription(
        systemAudioURL: URL,
        meetingDuration: Double
    ) async -> [SpeechSegment] {
        fputs("[meeting] no system chunks survived, falling back to full-session system transcription\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeeting(
                at: systemAudioURL,
                backend: backend,
                cohereLanguage: config.resolvedCohereLanguage
            )
            return normalizeSystemTranscription(
                result: result,
                startTime: 0,
                endTime: meetingDuration
            )
        } catch {
            fputs("[meeting] full-session system fallback transcription failed: \(error)\n", stderr)
            return []
        }
    }
}
