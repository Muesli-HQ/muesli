import Foundation
import MuesliCore

/// A decoder produced a hypothesis that cannot yet be tied to the supplied
/// audio. Preserve the last valid preview and retry only after more audio.
enum BufferedTranscriptionPreviewDeferral: String, Error, Sendable {
    case missingWordTimings = "missing_word_timings"
    case textAlignmentMismatch = "text_alignment_mismatch"
    case invalidWordTimings = "invalid_word_timings"
    case collapsedWordTimings = "collapsed_word_timings"
}

/// Word times are relative to the start of the PCM supplied to the decoder.
struct BufferedTranscriptionWord: Sendable, Equatable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Float?

    init(text: String, start: Double, end: Double, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

struct BufferedTranscriptionWindow: Sendable {
    let text: String
    let words: [BufferedTranscriptionWord]

    /// Preserve the decoder's punctuation, whitespace and scripts when splitting
    /// the result into timed words. Missing/unmatched timing is a preview failure,
    /// never permission to drop text during a window rollover.
    static func aligned(text: String, words: [BufferedTranscriptionWord]) throws -> Self {
        var cursor = text.startIndex
        var aligned: [BufferedTranscriptionWord] = []
        for word in words {
            let spelling = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spelling.isEmpty else { continue }
            guard let range = text.range(of: spelling, range: cursor..<text.endIndex),
                  text[cursor..<range.lowerBound].allSatisfy({ $0.isWhitespace }) else {
                throw BufferedTranscriptionSession.Failure.invalidTimings
            }
            aligned.append(.init(text: String(text[cursor..<range.upperBound]), start: word.start, end: word.end, confidence: word.confidence))
            cursor = range.upperBound
        }
        guard text[cursor...].allSatisfy({ $0.isWhitespace }) else {
            throw BufferedTranscriptionSession.Failure.invalidTimings
        }
        return Self(text: text, words: aligned)
    }
}

struct BufferedTranscriptionUpdate: Sendable, Equatable {
    let committedText: String
    let tail: String
    let revision: UInt64
    var text: String { committedText + tail }

    init(committedText: String, tail: String, revision: UInt64 = 0) {
        self.committedText = committedText
        self.tail = tail
        self.revision = revision
    }
}

/// Buffered previews supply final text after validated ownership and complete
/// audio coverage. Confidence is diagnostic; structural failures retain partial
/// text and the recording for explicit recovery.
/// Audio capture never waits for inference. There is one decoder in flight and
/// new arrivals coalesce into the next snapshot. Audio-time ownership, rather
/// than matching strings, preserves deliberately repeated words at rollovers.
final class BufferedTranscriptionSession: @unchecked Sendable {
    struct Diagnostics: Sendable {
        let receivedSamples: Int
        let decodeCount: Int
        let revision: UInt64
        let closed: Bool
    }

    struct Configuration: Sendable {
        var minimumSamples = 32_000
        var updateSamples = 16_000
        var windowSamples = 240_000
        var rightContextSamples = 48_000
        var leftContextSamples = 16_000
        var maximumBufferedSamples = 720_000
        var maximumRecoveryWindowSamples = 480_000
        /// Consecutive window timings may move slightly as context grows.
        var maximumTimestampDrift: Double = 0.25
        /// Only suppress an entirely silent window. Quiet speech is not trimmed.
        var silenceRMS: Float = 0.0001
        /// Presentation only; never changes word ownership or PCM trimming.
        var smoothWhisperPreviews = false
        /// Whisper's local agreement ignores cosmetic revisions and can use a
        /// following timed word as context instead of the fixed age cutoff.
        var lexicalAgreement = false

        static var whisper: Self {
            var configuration = Self()
            configuration.smoothWhisperPreviews = true
            configuration.lexicalAgreement = true
            // Bound repeated decoding and the wait for an ordinary rollover.
            // Timestamp tolerances and the recovery budget are unchanged.
            configuration.windowSamples = 128_000
            return configuration
        }
    }

    /// Provisional telemetry thresholds, not finalization gates or calibrated correctness.
    /// Agreement supplies stronger evidence than a single final/forced hypothesis.
    enum ReusePolicy {
        static let agreedConfidenceFloor: Float = 0.15
        static let unagreedConfidenceFloor: Float = 0.8
    }

    enum ReuseFallbackReason: String, Sendable {
        case cancelled, transcriptionFailed, noAudio, incompleteCoverage
        case missingConfidence, invalidConfidence, lowConfidence
        case unagreedContextTooLong, unsupportedWordTiming
        case committedTranscriptChanged, unverifiedEmptyAudio

        /// Quality uncertainty never requests a new full-session transcription.
        /// Coverage, alignment, and lifecycle failures still prevent completion.
        var preventsReuse: Bool {
            switch self {
            case .cancelled, .transcriptionFailed, .noAudio, .incompleteCoverage:
                return true
            case .missingConfidence, .invalidConfidence, .lowConfidence, .unagreedContextTooLong,
                 .unsupportedWordTiming, .committedTranscriptChanged, .unverifiedEmptyAudio:
                return false
            }
        }
    }

    struct ReuseDiagnostics: Sendable, CustomStringConvertible {
        let qualityConcern: ReuseFallbackReason?
        let committedWordCount: Int
        let agreedWordCount: Int
        let unagreedWordCount: Int
        let missingConfidenceCount: Int
        let invalidConfidenceCount: Int
        let lowConfidenceCount: Int
        let minimumConfidence: Float?
        let maximumUnagreedSpan: Double
        let discardedSamples: Int
        let firstLowConfidenceEvidence: String?
        let lastLowConfidenceEvidence: String?
        var description: String {
            "qualityConcern=\(qualityConcern?.rawValue ?? "none"):words=\(committedWordCount):agreed=\(agreedWordCount):unagreed=\(unagreedWordCount):missing=\(missingConfidenceCount):invalid=\(invalidConfidenceCount):low=\(lowConfidenceCount):minConfidence=\(minimumConfidence.map(String.init(describing:)) ?? "none"):maxUnagreedSpan=\(maximumUnagreedSpan):discardedSamples=\(discardedSamples):firstLow=[\(firstLowConfidenceEvidence ?? "none")]:lastLow=[\(lastLowConfidenceEvidence ?? "none")]"
        }
    }

    struct ReuseResult: Sendable {
        /// Diagnostic text may be partial when completed is false. Callers must
        /// check canReuse and recording sample-count equality before using it.
        let text: String
        let canReuse: Bool
        let completed: Bool
        let fallbackReason: ReuseFallbackReason?
        let receivedSamples: Int
        let decodedThroughSample: Int
        let diagnostics: ReuseDiagnostics
    }

    private struct ReuseQuality {
        var qualityConcern: ReuseFallbackReason?
        var structuralReason: ReuseFallbackReason?
        var committedWords = 0
        var agreedWords = 0
        var unagreedWords = 0
        var missingConfidence = 0
        var invalidConfidence = 0
        var lowConfidence = 0
        var minimumConfidence: Float?
        var maximumUnagreedSpan: Double = 0
        var currentUnagreedStart: Double?
        var currentUnagreedEnd: Double?
        var firstLowConfidenceEvidence: String?
        var lastLowConfidenceEvidence: String?

        mutating func recordConcern(_ reason: ReuseFallbackReason) {
            if reason.preventsReuse {
                if structuralReason == nil { structuralReason = reason }
            } else if qualityConcern == nil {
                qualityConcern = reason
            }
        }
    }

    enum Failure: Error, LocalizedError {
        case audioOverrun, invalidTimings, cannotAdvance, ownershipUnresolved
        var errorDescription: String? {
            switch self {
            case .audioOverrun: return "Live transcription could not keep up. The recording is still available for final transcription."
            case .invalidTimings: return "Live transcription returned unusable word timing."
            case .cannotAdvance: return "Live transcription could not safely advance its audio window."
            case .ownershipUnresolved: return "Live transcription could not resolve its audio boundary with additional context. The recording remains available for final transcription."
            }
        }
    }

    private enum RecoveryReason: String {
        case missingAnchor = "missing_anchor"
        case ambiguousAnchor = "ambiguous_anchor"
        case changedAnchor = "changed_anchor_waiting"
        case changedBoundary = "changed_boundary"
        case emptyHypothesis = "empty_hypothesis"
        case noRollProgress = "no_roll_progress"
        case inseparableTimings = "inseparable_timings"
        case unusablePreview = "unusable_preview"
    }
    private struct AlignmentRecovery: Error {
        let reason: RecoveryReason
        var candidate: [BufferedTranscriptionWord]? = nil
        var agreementTail: [BufferedTranscriptionWord]? = nil
    }

    private struct State {
        var audio: [Float] = []
        var offset = 0
        var lastDecodedEnd = 0
        // Frozen at commitment, never revised by a later lexical hypothesis.
        var committedAudioThrough = 0
        var continuity = false
        var alignmentDeferrals = 0
        var lastCommitSnapshotEnd = 0
        // No audio is owned at session start, including a word timed at (0, 0).
        var ownedUntil: Double?
        var committedText = ""
        var committedAnchors: [BufferedTranscriptionWord] = []
        // Early Whisper commitments may outlast the four retained anchors.
        // Keep their furthest decoded end until the silence cutoff passes it.
        var maximumOwnedWordEnd: Double?
        var previousTail: [BufferedTranscriptionWord] = []
        var previousTailReuseAgreement: [Bool] = []
        var continuityRecovery: (text: String, throughSample: Int)?
        var lastPublishedThroughSample = 0
        var lastPublishedTail = ""
        var lastPresentedTail = ""
        var presentation = WhisperPreviewPresentation()
        var recovering = false
        var recoveryCandidate: [BufferedTranscriptionWord]?
        var followingAnchor: BufferedTranscriptionWord?
        var revision: UInt64 = 0
        var receivedSamples = 0
        var decodeCount = 0
        var reuseQuality = ReuseQuality()
        var reuseTerminalReason: ReuseFallbackReason?
        var finalText: String?
        var decodedThroughSample = 0
        var running = false
        var finishing = false
        var closed = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private struct Snapshot {
        let audio: [Float]
        let offset: Int
        let final: Bool
    }

    // Callback delivery shares this lock with cancellation, so no callback can
    // start after cancel() returns. Recursive permits a callback to cancel.
    private let lock = NSRecursiveLock()
    private var state = State()
    // Lifecycle state must not be restored by alignment's transactional rollback.
    // Access is protected by the same recursive lock as State.
    private var drainTask: (id: UUID, task: Task<Void, Never>)?
    private let configuration: Configuration
    private let decode: @Sendable ([Float]) async throws -> BufferedTranscriptionWindow
    private let decodeWithoutTimings: (@Sendable ([Float]) async throws -> String)?
    private let onUpdate: @Sendable (BufferedTranscriptionUpdate) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let onDiagnostic: @Sendable (String) -> Void

    var knownReuseFallbackReason: ReuseFallbackReason? {
        synchronized { state.reuseTerminalReason ?? state.reuseQuality.structuralReason }
    }

    /// Best raw hypothesis, including the undecided tail, for saved recovery.
    /// This accessor makes no claim that the stream completed successfully.
    var currentTranscript: String {
        synchronized { state.finalText ?? state.continuityRecovery?.text ?? (state.committedText + state.lastPublishedTail) }
    }

    var reuseDiagnostics: ReuseDiagnostics {
        synchronized { reuseResult(cancelled: false).diagnostics }
    }

    var diagnostics: Diagnostics {
        synchronized {
            Diagnostics(receivedSamples: state.receivedSamples, decodeCount: state.decodeCount,
                        revision: state.revision, closed: state.closed)
        }
    }

    private let onSilentAudio: @Sendable (Int) -> Void
    private let measurement: (@Sendable (String) -> BodhanWBCSMeasurement)?
    func bodhanMeasurement(for text: String) -> BodhanWBCSMeasurement? { measurement?(text) }

    init(
        configuration: Configuration = .init(),
        decode: (@Sendable ([Float]) async throws -> BufferedTranscriptionWindow)? = nil,
        decodeWithoutTimings: (@Sendable ([Float]) async throws -> String)? = nil,
        measurement: (@Sendable (String) -> BodhanWBCSMeasurement)? = nil,
        onSilentAudio: @escaping @Sendable (Int) -> Void = { _ in },
        onUpdate: @escaping @Sendable (BufferedTranscriptionUpdate) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void,
        onDiagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        precondition(configuration.minimumSamples > 0 && configuration.updateSamples > 0)
        precondition(configuration.windowSamples > configuration.minimumSamples)
        precondition(configuration.rightContextSamples > 0 && configuration.leftContextSamples >= 0)
        precondition(configuration.rightContextSamples + configuration.leftContextSamples < configuration.windowSamples)
        precondition(configuration.maximumBufferedSamples >= configuration.windowSamples)
        precondition(configuration.maximumRecoveryWindowSamples >= configuration.windowSamples)
        precondition(configuration.maximumTimestampDrift > 0 && configuration.maximumTimestampDrift.isFinite)
        self.onSilentAudio = onSilentAudio
        self.measurement = measurement
        self.configuration = configuration
        precondition(decode != nil || decodeWithoutTimings != nil)
        self.decode = decode ?? { _ in throw Failure.invalidTimings }
        self.decodeWithoutTimings = decodeWithoutTimings
        self.onUpdate = onUpdate
        self.onFailure = onFailure
        self.onDiagnostic = onDiagnostic
        // Untimed backends own disjoint PCM chunks from the first update.
        state.continuity = decode == nil
    }

    func enqueue(_ samples: [Float]) {
        synchronized {
            guard !state.closed, !state.finishing, !samples.isEmpty else { return }
            guard samples.count <= configuration.maximumBufferedSamples - state.audio.count,
                  samples.allSatisfy(\.isFinite) else {
                onDiagnostic("audio_buffer_overrun:retained=\(state.audio.count):incoming=\(samples.count):limit=\(configuration.maximumBufferedSamples)")
                guard !state.closed else { return }
                fail(Failure.audioOverrun)
                return
            }
            state.audio.append(contentsOf: samples)
            state.receivedSamples += samples.count
            startIfNeeded()
        }
    }

    func cancel() {
        synchronized { close(reason: .cancelled) }
    }

    /// Closes capture and drains all accepted samples. Failures use onFailure;
    /// cancellation returns promptly even when the model cannot cancel inference.
    func finish() async {
        await withCheckedContinuation { continuation in
            synchronized {
                guard !state.closed else { continuation.resume(); return }
                state.finishing = true
                state.waiters.append(continuation)
                startIfNeeded()
            }
        }
    }

    /// Drains the retained tail using the established streaming policy. Quality
    /// concerns remain telemetry; successful ownership and complete sample
    /// coverage permit reuse. Cancellation returns partial text promptly without
    /// waiting for an uncooperative decoder.
    func finishForReuse() async -> ReuseResult {
        await withTaskCancellationHandler {
            await finish()
            return synchronized { reuseResult(cancelled: Task.isCancelled) }
        } onCancel: {
            self.cancel()
        }
    }

    private func reuseResult(cancelled: Bool) -> ReuseResult {
        let quality = state.reuseQuality
        let completed = state.finalText != nil && state.closed && state.reuseTerminalReason == nil
            && state.decodedThroughSample == state.receivedSamples
        let reason: ReuseFallbackReason? = cancelled ? .cancelled
            : state.reuseTerminalReason ?? quality.structuralReason ?? (completed ? nil : .incompleteCoverage)
        return ReuseResult(text: state.finalText ?? state.continuityRecovery?.text ?? (state.committedText + state.lastPublishedTail),
            canReuse: completed && reason == nil, completed: completed && !cancelled,
            fallbackReason: reason, receivedSamples: state.receivedSamples,
            decodedThroughSample: state.decodedThroughSample,
            diagnostics: .init(qualityConcern: quality.qualityConcern, committedWordCount: quality.committedWords, agreedWordCount: quality.agreedWords,
                unagreedWordCount: quality.unagreedWords, missingConfidenceCount: quality.missingConfidence,
                invalidConfidenceCount: quality.invalidConfidence, lowConfidenceCount: quality.lowConfidence,
                minimumConfidence: quality.minimumConfidence, maximumUnagreedSpan: quality.maximumUnagreedSpan,
                discardedSamples: state.offset, firstLowConfidenceEvidence: quality.firstLowConfidenceEvidence,
                lastLowConfidenceEvidence: quality.lastLowConfidenceEvidence))
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func startIfNeeded() {
        guard !state.running, !state.closed else { return }
        let minimum = state.continuity ? continuityChunkSamples : configuration.minimumSamples
        guard state.finishing || state.audio.count >= minimum else { return }
        guard state.finishing || state.continuity || state.offset + state.audio.count - state.lastDecodedEnd >= configuration.updateSamples else { return }
        state.running = true
        let id = UUID()
        // This runs under lock, so a new task cannot reach snapshot()/close()
        // before its handle has been published here.
        let task = Task {
            await drain()
            synchronized {
                // A new arrival can start another drain after snapshot marks
                // this one idle; its cancellation handle must remain intact.
                if drainTask?.id == id { drainTask = nil }
            }
        }
        drainTask = (id, task)
    }

    private func snapshot() -> Snapshot? {
        synchronized {
            guard !state.closed else { state.running = false; return nil }
            if state.finishing && state.audio.isEmpty {
                if state.continuity && state.receivedSamples > 0 && state.decodedThroughSample == state.receivedSamples {
                    state.finalText = state.committedText
                    close()
                } else {
                    close(reason: state.receivedSamples == 0 ? .noAudio : .incompleteCoverage)
                }
                return nil
            }
            if state.continuity {
                guard state.finishing || state.audio.count >= continuityChunkSamples else {
                    state.running = false
                    return nil
                }
                let count = min(state.audio.count, continuityChunkSamples)
                return Snapshot(audio: Array(state.audio.prefix(count)), offset: state.offset,
                                final: state.finishing && count == state.audio.count)
            }
            let end = state.offset + state.audio.count
            if !state.finishing && (state.audio.count < configuration.minimumSamples || end - state.lastDecodedEnd < configuration.updateSamples) {
                state.running = false
                return nil
            }
            let limit = state.recovering ? recoveryWindowLimit : configuration.windowSamples
            let count = min(state.audio.count, limit)
            if state.recovering && state.offset + count <= state.lastDecodedEnd {
                if state.finishing {
                    onDiagnostic("ownership_recovery_exhausted:finish_without_new_audio")
                    if !state.closed, beginContinuity(snapshotEnd: state.lastDecodedEnd) { return snapshot() }
                    if !state.closed { fail(Failure.ownershipUnresolved) }
                } else {
                    state.running = false
                }
                return nil
            }
            return Snapshot(audio: Array(state.audio.prefix(count)), offset: state.offset,
                            final: state.finishing && count == state.audio.count)
        }
    }

    private func drain() async {
        while let snapshot = snapshot() {
            do {
                if synchronized({ state.continuity }), let decodeWithoutTimings {
                    let decodeStarted = ProcessInfo.processInfo.systemUptime
                    let rms = sqrt(snapshot.audio.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, snapshot.audio.count)))
                    let text: String
                    if rms <= Double(configuration.silenceRMS) {
                        text = ""
                    } else {
                        let canDecode = synchronized {
                            guard !state.closed else { return false }
                            state.decodeCount += 1
                            return true
                        }
                        guard canDecode else { return }
                        try Task.checkCancellation()
                        text = try await decodeWithoutTimings(snapshot.audio)
                    }
                    synchronized {
                        guard !state.closed else { return }
                        let decodeMilliseconds = Int((ProcessInfo.processInfo.systemUptime - decodeStarted) * 1_000)
                        onDiagnostic("continuity_decode:audioMs=\(snapshot.audio.count / 16):decodeMs=\(decodeMilliseconds):final=\(snapshot.final)")
                        guard !state.closed else { return }
                        if rms <= Double(configuration.silenceRMS) { onSilentAudio(snapshot.audio.count) }
                        acceptContinuity(text, snapshot: snapshot)
                    }
                    continue
                }
                let decodeStarted = ProcessInfo.processInfo.systemUptime
                let rms = sqrt(snapshot.audio.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, snapshot.audio.count)))
                let result: BufferedTranscriptionWindow
                if rms <= Double(configuration.silenceRMS) {
                    result = BufferedTranscriptionWindow(text: "", words: [])
                } else {
                    let canDecode = synchronized {
                        guard !state.closed else { return false }
                        state.decodeCount += 1
                        return true
                    }
                    guard canDecode else { return }
                    try Task.checkCancellation()
                    result = try await decode(snapshot.audio)
                }
                try synchronized {
                    guard !state.closed else { return }
                    let decodeMilliseconds = Int((ProcessInfo.processInfo.systemUptime - decodeStarted) * 1_000)
                    onDiagnostic("decode:audioMs=\(snapshot.audio.count / 16):decodeMs=\(decodeMilliseconds):final=\(snapshot.final)")
                    guard !state.closed else { return }
                    // accept can update anchors before discovering that a roll
                    // cannot advance. Recovery must restore the entire proposal,
                    // including PCM, before deferring this observation.
                    let checkpoint = state
                    do {
                        try accept(result, snapshot: snapshot, isSilent: rms <= Double(configuration.silenceRMS))
                    } catch let recovery as AlignmentRecovery {
                        state = checkpoint
                        deferAlignment(recovery, snapshot: snapshot)
                    } catch Failure.invalidTimings where decodeWithoutTimings != nil {
                        state = checkpoint
                        deferAlignment(AlignmentRecovery(reason: .unusablePreview), snapshot: snapshot)
                    }
                }
            } catch let deferral as BufferedTranscriptionPreviewDeferral {
                synchronized {
                    guard !state.closed else { return }
                    // Untimed decoding has no recoverable timing contract. A
                    // decoder violating that contract must not spin on one chunk.
                    if state.continuity { fail(deferral); return }
                    onDiagnostic("preview_deferred:\(deferral.rawValue)")
                    guard !state.closed else { return }
                    deferAlignment(AlignmentRecovery(reason: .unusablePreview), snapshot: snapshot)
                }
            } catch {
                synchronized { if !state.closed { fail(error) } }
            }
        }
    }

    private func accept(_ result: BufferedTranscriptionWindow, snapshot: Snapshot, isSilent: Bool) throws {
        let result = try BufferedTranscriptionWindow.aligned(text: result.text, words: result.words)
        let duration = Double(snapshot.audio.count) / 16_000
        var previousStart = -Double.infinity
        for word in result.words {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0,
                  word.start >= previousStart, word.end >= word.start,
                  word.end <= duration + 0.25 else { throw Failure.invalidTimings }
            previousStart = word.start
        }
        guard result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !result.words.isEmpty else {
            throw Failure.invalidTimings
        }
        let rolls = snapshot.audio.count >= configuration.windowSamples && !snapshot.final
        // An empty decoder result does not establish ownership of audible PCM.
        // Keep the window for bounded context recovery rather than discarding a
        // lead that a later hypothesis could recognize. The existing acoustic
        // silence bypass may still advance without inventing sentence boundaries.
        if result.words.isEmpty, !isSilent, rolls || state.recovering {
            throw AlignmentRecovery(reason: .emptyHypothesis)
        }
        if result.words.isEmpty && (!state.committedAnchors.isEmpty || !state.lastPublishedTail.isEmpty) {
            throw AlignmentRecovery(reason: .emptyHypothesis)
        }
        let base = Double(snapshot.offset) / 16_000
        let absoluteWords = result.words.map {
            BufferedTranscriptionWord(text: $0.text, start: base + $0.start, end: base + $0.end, confidence: $0.confidence)
        }
        let unownedStart = try unownedStart(in: absoluteWords, base: base)
        if let ownedEnd = absoluteWords.prefix(unownedStart).map(\.end).max() {
            state.maximumOwnedWordEnd = max(state.maximumOwnedWordEnd ?? ownedEnd, ownedEnd)
        }
        let words = Array(absoluteWords.dropFirst(unownedStart))
        let matureUntil = base + duration - Double(configuration.rightContextSamples) / 16_000
        let matureCount = words.prefix { $0.end <= matureUntil }.count
        var agreementCount = 0
        for (previous, current) in zip(state.previousTail, words) {
            // Position and both timestamps still identify the same occurrence.
            // Whisper may change edge punctuation/casing indefinitely despite
            // agreeing on the word. Freeze its latest rendering without holding
            // the entire following prefix hostage to those cosmetic revisions.
            guard wordsAgree(previous, current) else { break }
            agreementCount += 1
        }
        let reuseAgreement = reuseAgreement(for: words, freshCoverage: snapshot.offset + snapshot.audio.count > state.lastDecodedEnd)
        // A full encoder window must advance even after a coalesced first decode.
        // Its existing right-context policy remains the bounded fallback; shorter
        // windows now freeze agreed prefixes instead of rewriting whole sentences.
        // Local agreement plus a following timed word already establishes a
        // complete prefix. Whisper should not wait another three seconds for
        // that prefix; the right-context budget remains the rollover fallback
        // for words that have not agreed, and for an isolated final word.
        var confirmedCount = configuration.lexicalAgreement ? min(agreementCount, max(0, words.count - 1)) : 0
        while confirmedCount > 0, words[confirmedCount].end == words[confirmedCount].start {
            confirmedCount -= 1
        }
        // Maturity is an evidence budget, not a reason to wait for the next
        // physical crop. A stable ordered seam can close a mature prefix even
        // when an earlier unowned word is still revising its spelling or onset.
        let stableSeamCount = !rolls && !snapshot.final
            && snapshot.offset + snapshot.audio.count > state.lastDecodedEnd
            ? maturePrefixWithStableSeam(words, matureCount: matureCount) : 0
        let matureCommitCount = rolls ? matureCount : max(min(matureCount, agreementCount), stableSeamCount)
        var commitCount = snapshot.final ? words.count : max(confirmedCount, matureCommitCount)
        // Preserve quantized zero-duration words, but never make one the live
        // boundary anchor. Whisper can later relocate that onset substantially,
        // leaving a lone committed word unmatchable for many decoding passes.
        // Keep it pending until a positive-duration neighbor can anchor the group;
        // finalization still flushes every word, including a lone zero-timed word.
        let proposedCount = commitCount
        var zeroAnchorHeld = 0
        if !snapshot.final, configuration.lexicalAgreement {
            while commitCount > 0, words[commitCount - 1].end == words[commitCount - 1].start {
                commitCount -= 1
            }
            zeroAnchorHeld = proposedCount - commitCount
            // After startup or a long silent roll there is no preceding anchor
            // to corroborate an onset revision. Establish a small timed group,
            // rather than freezing one speculative word as the sole boundary.
            if state.committedAnchors.isEmpty {
                let lexicalCount = words.prefix(commitCount).filter { $0.end > $0.start
                    && $0.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }.count
                // A real one-word utterance may be followed by any length pause.
                // Independent agreement plus mature context can confirm it.
                if lexicalCount == 0 || (lexicalCount < 2 && commitCount > min(matureCount, agreementCount)) {
                    commitCount = 0
                }
            }
        }
        if decodeWithoutTimings != nil, !snapshot.final, commitCount == 0, !words.isEmpty,
           snapshot.offset + snapshot.audio.count - state.lastCommitSnapshotEnd >= configuration.rightContextSamples + 2 * configuration.updateSamples {
            throw AlignmentRecovery(reason: .noRollProgress, agreementTail: words)
        }
        onDiagnostic("commit_policy:mature=\(matureCount):agreed=\(agreementCount):confirmed=\(confirmedCount):stableSeam=\(stableSeamCount):committed=\(commitCount):pending=\(words.count - commitCount):zeroAnchorHeld=\(zeroAnchorHeld):initialGroupHeld=\(proposedCount - zeroAnchorHeld - commitCount):roll=\(rolls)")
        guard !state.closed else { return }
        var retainFrom = base + duration
        var retainsLexicalAnchor = false
        if commitCount > 0 {
            let committed = Array(words.prefix(commitCount))
            if let ownedEnd = committed.map(\.end).max() {
                state.maximumOwnedWordEnd = max(state.maximumOwnedWordEnd ?? ownedEnd, ownedEnd)
            }
            recordReuseQuality(committed, agreement: Array(reuseAgreement.prefix(commitCount)))
            let last = committed[committed.count - 1]
            let next = words.dropFirst(commitCount).first
            let ownedUntil = try ownershipBoundary(after: last, before: next)
            state.ownedUntil = ownedUntil
            state.committedAudioThrough = max(state.committedAudioThrough,
                min(snapshot.offset + snapshot.audio.count, Int(ownedUntil * 16_000)))
            state.lastCommitSnapshotEnd = snapshot.offset + snapshot.audio.count
            // Keep the last owned word available as a timing anchor at rollover,
            // including when a long word starts before the usual left context.
            retainFrom = min(ownedUntil, next?.start ?? ownedUntil,
                             last.start)
            retainsLexicalAnchor = true
            state.committedText += join(committed, after: state.committedText)
            state.committedAnchors = Array((state.committedAnchors + committed).suffix(4))
            let ownedEnd = configuration.lexicalAgreement ? state.maximumOwnedWordEnd ?? last.end : last.end
            if rolls, (next?.start ?? matureUntil) >= matureUntil,
               ownedEnd + Double(configuration.leftContextSamples) / 16_000 + configuration.maximumTimestampDrift < matureUntil {
                // A long decoded silence after the last word needs no lexical
                // anchor. Retain its right context and own only the silent lead.
                state.ownedUntil = matureUntil
                retainFrom = matureUntil
                retainsLexicalAnchor = false
            }
        } else if rolls {
            let lastOwnedEnd = configuration.lexicalAgreement
                ? state.maximumOwnedWordEnd : state.committedAnchors.last?.end
            let hasSilentLead = lastOwnedEnd.map {
                $0 + Double(configuration.leftContextSamples) / 16_000
                    + configuration.maximumTimestampDrift < matureUntil
            } ?? true
            // A next word at the maturity cutoff is not itself evidence of a
            // long pause. Preserve nearby owned onsets and their timing margin.
            // Empty pending text does not mean every early-owned word ended.
            // Keep a lexical seam while any earlier owned interval crosses it.
            if (words.isEmpty && (!configuration.lexicalAgreement || hasSilentLead))
                || ((words.first?.start ?? base) >= matureUntil && hasSilentLead) {
                // There is no unowned speech in this leading span. Its old anchors
                // may leave the retained PCM; the absolute time boundary then owns it.
                state.ownedUntil = max(state.ownedUntil ?? -.infinity, matureUntil)
                retainFrom = matureUntil
            } else if let lastOwned = state.committedAnchors.last, let ownedUntil = state.ownedUntil {
                // A fractional rolling window can end while the next word
                // straddles the maturity cutoff. Previously owned audio still
                // provides safe progress; no additional commitment is required.
                retainFrom = min(ownedUntil, words.first?.start ?? ownedUntil, lastOwned.start)
                retainsLexicalAnchor = true
            } else {
                throw AlignmentRecovery(reason: .noRollProgress, agreementTail: words)
            }
        }
        let tailWords = Array(words.dropFirst(commitCount))
        let tail = join(tailWords, after: state.committedText)
        // Preserve agreement across rolls in absolute audio time.
        state.previousTail = tailWords
        state.previousTailReuseAgreement = Array(reuseAgreement.dropFirst(commitCount))
        state.lastPublishedTail = tail
        state.lastPublishedThroughSample = snapshot.offset + snapshot.audio.count
        state.followingAnchor = tailWords.first
        state.lastDecodedEnd = snapshot.offset + snapshot.audio.count
        state.decodedThroughSample = state.lastDecodedEnd
        // Empty recognition over nonzero microphone noise is acoustic uncertainty,
        // not missing sample coverage. Preserve it as quality telemetry only once
        // that decoded span is discarded or finalized.
        if (rolls || snapshot.final), result.words.isEmpty,
           snapshot.audio.contains(where: { $0 != 0 }) {
            state.reuseQuality.recordConcern(.unverifiedEmptyAudio)
        }
        if rolls {
            if retainsLexicalAnchor, let preceding = state.committedAnchors.dropLast().last {
                // An owned onset can move into a preceding pause after cropping.
                // Keep its predecessor so the existing two-sided boundary check
                // still has evidence. Long words/gaps must not pin the window:
                // retain this extra context only when a full update can advance.
                let contextualStart = min(retainFrom, preceding.start)
                let contextualDiscard = Int(contextualStart * 16_000) - configuration.leftContextSamples - state.offset
                if contextualDiscard >= configuration.updateSamples { retainFrom = contextualStart }
            }
            // Once a decoded silent lead has retired every lexical anchor and
            // there is no pending word, old context is already owned. Feeding it
            // back to Whisper can hallucinate a new phrase over the pause.
            // Keep left context whenever an anchor or an unfinished word needs it.
            // An empty new tail can also follow an early-agreed owned word
            // spanning the cutoff. Preserve its onset until that word has ended;
            // cropping it could make the remaining suffix appear to be new speech.
            let ownedWordsEnded = configuration.lexicalAgreement
                ? (state.maximumOwnedWordEnd.map { $0 <= retainFrom } ?? true)
                : state.committedAnchors.allSatisfy { $0.end <= retainFrom }
            let leftContext = configuration.lexicalAgreement && !retainsLexicalAnchor && tailWords.isEmpty && ownedWordsEnded
                ? 0 : configuration.leftContextSamples
            let discard = Int(retainFrom * 16_000) - leftContext - state.offset
            guard discard > 0, discard <= state.audio.count else {
                throw AlignmentRecovery(reason: .noRollProgress, agreementTail: words)
            }
            state.audio.removeFirst(discard)
            state.offset += discard
            let newBase = Double(state.offset) / 16_000
            // The matcher needs an anchor's complete onset in retained PCM.
            // An owned word's end can extend through a pause and straddle this
            // crop even though its onset is gone. Keeping that ineligible anchor
            // would block the existing absolute-time ownership path forever.
            state.committedAnchors.removeAll { $0.start < newBase }
        }
        state.alignmentDeferrals = 0
        if state.recovering {
            state.recovering = false
            state.recoveryCandidate = nil
            onDiagnostic("ownership_recovered:samples=\(snapshot.audio.count)")
            guard !state.closed else { return }
        }
        state.revision += 1
        let visibleTail = configuration.smoothWhisperPreviews
            ? state.presentation.present(committedText: state.committedText, tail: tail,
                                         words: tailWords, final: snapshot.final) : tail
        state.lastPresentedTail = visibleTail
        onUpdate(.init(committedText: state.committedText, tail: visibleTail, revision: state.revision))
        if snapshot.final, !state.closed {
            guard state.decodedThroughSample == state.receivedSamples else {
                close(reason: .incompleteCoverage)
                return
            }
            state.finalText = state.committedText + tail
            close()
        }
    }

    /// Locate already-owned words using ordered, timed anchors, not textual
    /// overlap removal. Refresh their positions on every decode so small timing
    /// jitter cannot push an owned repeated word back into the draft tail.
    private func unownedStart(in words: [BufferedTranscriptionWord], base: Double) throws -> Int {
        guard !state.committedAnchors.isEmpty else {
            guard let ownedUntil = state.ownedUntil else { return 0 }
            // Silent ownership is half-open: a zero-duration word exactly at
            // its right edge was not committed and must survive the next roll.
            return words.prefix { ($0.start + $0.end) / 2 < ownedUntil }.count
        }
        let anchors = state.committedAnchors.filter { $0.start >= base }
        guard !anchors.isEmpty else { throw AlignmentRecovery(reason: .missingAnchor) }
        var matchedIndex: Int?
        // Earlier committed words may be revised by the model. Try the longest
        // retained suffix first, never resolving multiple candidates by proximity.
        // Match onsets: a decoder can extend an owned word's end across silence
        // when more context arrives. That duration revision is not a new occurrence.
        // End times still undergo global validation and new-commit agreement.
        for length in stride(from: anchors.count, through: 1, by: -1) {
            let suffix = anchors.suffix(length)
            var candidates: [Int] = []
            for index in words.indices where index + 1 >= length {
                let match = words[(index + 1 - length)...index]
                let valid = zip(suffix, match).allSatisfy { anchor, candidate in
                    anchorIdentity(anchor.text) == anchorIdentity(candidate.text)
                        && abs(anchor.start - candidate.start) <= configuration.maximumTimestampDrift
                }
                if valid { candidates.append(index) }
            }
            guard candidates.count <= 1 else { throw AlignmentRecovery(reason: .ambiguousAnchor) }
            if let index = candidates.first { matchedIndex = index; break }
        }
        if matchedIndex == nil, anchors.count >= 2, let following = state.followingAnchor {
            // More context can expand or shorten an owned word's onset span
            // without moving its end or the next word. Require the preceding
            // lexical/timed context and the following seam; an end timestamp
            // alone cannot own a repeat.
            for length in stride(from: anchors.count, through: 2, by: -1) {
                let suffix = Array(anchors.suffix(length))
                let last = suffix[length - 1]
                let candidates = words.indices.filter { index in
                    guard index + 1 >= length, index + 1 < words.count else { return false }
                    let current = words[index]
                    let next = words[index + 1]
                    guard anchorIdentity(current.text) == anchorIdentity(last.text),
                          abs(current.end - last.end) <= configuration.maximumTimestampDrift,
                          // A pause may move from the preceding word's end to
                          // this onset. Check their current adjacency; the fixed
                          // outer onsets/end and lexical neighbors prove the seam.
                          current.start >= words[index - 1].end - configuration.maximumTimestampDrift,
                          anchorIdentity(next.text) == anchorIdentity(following.text),
                          abs(next.start - following.start) <= configuration.maximumTimestampDrift else { return false }
                    return zip(suffix.dropLast(), words[(index + 1 - length)..<index]).allSatisfy {
                        anchorIdentity($0.text) == anchorIdentity($1.text)
                            && abs($0.start - $1.start) <= configuration.maximumTimestampDrift
                    }
                }
                guard candidates.count <= 1 else { throw AlignmentRecovery(reason: .ambiguousAnchor) }
                if let index = candidates.first { matchedIndex = index; break }
            }
        }
        if matchedIndex == nil, configuration.lexicalAgreement {
            matchedIndex = revisedBoundary(in: words, anchors: anchors, following: state.followingAnchor)
            if matchedIndex != nil {
                state.reuseQuality.recordConcern(.committedTranscriptChanged)
                onDiagnostic("ownership_realigned:edited_context")
            }
        }
        if matchedIndex == nil {
            // A permanently revised lexical anchor can still identify the same
            // audio seam. Require a unique ordered onset alignment and agreement
            // on its NEW spelling in two different, growing audio hypotheses.
            for length in stride(from: anchors.count, through: 1, by: -1) {
                let suffix = anchors.suffix(length)
                let candidates = words.indices.filter { index in
                    guard index + 1 >= length else { return false }
                    return zip(suffix, words[(index + 1 - length)...index]).allSatisfy {
                        abs($0.start - $1.start) <= configuration.maximumTimestampDrift
                    }
                }
                guard candidates.count <= 1 else { throw AlignmentRecovery(reason: .ambiguousAnchor) }
                guard let index = candidates.first else { continue }
                let candidate = Array(words[(index + 1 - length)...index])
                let next = words.dropFirst(index + 1).first
                if let following = state.followingAnchor {
                    // A revised owned word must not split into extra tokens that
                    // are then mistaken for new speech (cannot -> can + not).
                    guard let next, anchorIdentity(next.text) == anchorIdentity(following.text),
                          abs(next.start - following.start) <= configuration.maximumTimestampDrift else {
                        throw AlignmentRecovery(reason: .changedBoundary)
                    }
                } else if let next, let last = anchors.last,
                          next.start <= last.end + configuration.maximumTimestampDrift {
                    throw AlignmentRecovery(reason: .changedBoundary)
                }
                if let previous = state.recoveryCandidate, previous.count == candidate.count,
                   zip(previous, candidate).allSatisfy({ old, new in
                       old.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.elementsEqual(
                           new.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
                           && abs(old.start - new.start) <= configuration.maximumTimestampDrift
                   }) {
                    if zip(suffix, candidate).contains(where: { anchorIdentity($0.text) != anchorIdentity($1.text) }) {
                        state.reuseQuality.recordConcern(.committedTranscriptChanged)
                    }
                    matchedIndex = index
                    break
                }
                throw AlignmentRecovery(reason: .changedAnchor, candidate: candidate)
            }
        }
        guard let matchedIndex else { throw AlignmentRecovery(reason: .missingAnchor) }
        let lastCurrent = words[matchedIndex]
        // A shorter suffix can legitimately recover live ownership while older
        // committed wording changed. Preserve frozen text under the streaming
        // policy and retain the revision as quality telemetry.
        if matchedIndex + 1 < anchors.count {
            state.reuseQuality.recordConcern(.committedTranscriptChanged)
        } else {
            let currentOwned = words[(matchedIndex + 1 - anchors.count)...matchedIndex]
            if !zip(anchors, currentOwned).allSatisfy({ anchorIdentity($0.text) == anchorIdentity($1.text) }) {
                state.reuseQuality.recordConcern(.committedTranscriptChanged)
            }
        }
        state.committedAnchors = Array(words.prefix(matchedIndex + 1).suffix(4))
        state.ownedUntil = try ownershipBoundary(after: lastCurrent,
                                               before: words.dropFirst(matchedIndex + 1).first)
        return matchedIndex + 1
    }

    /// Match the occurrence around a revised endpoint without requiring equal
    /// token counts. A timed longest common subsequence tolerates insertions and
    /// deletions inside the already-owned context. It never edits visible text.
    /// Two unchanged context words and a unique overlapping endpoint are needed;
    /// neither confidence nor the spelling of that endpoint gates progress.
    private func revisedBoundary(in words: [BufferedTranscriptionWord],
                                 anchors: [BufferedTranscriptionWord],
                                 following: BufferedTranscriptionWord?) -> Int? {
        guard anchors.count >= 3, let last = anchors.last, last.end > last.start else { return nil }
        let context = Array(anchors.dropLast())
        // scores[j] is the longest ordered, lexical/timed match between the
        // context and words before j. Gaps represent decoder token revisions.
        var scores = Array(repeating: 0, count: words.count + 1)
        for anchor in context {
            var next = Array(repeating: 0, count: words.count + 1)
            for j in words.indices {
                if anchorIdentity(anchor.text) == anchorIdentity(words[j].text),
                   abs(anchor.start - words[j].start) <= configuration.maximumTimestampDrift {
                    next[j + 1] = max(scores[j] + 1, max(scores[j + 1], next[j]))
                } else {
                    next[j + 1] = max(scores[j + 1], next[j])
                }
            }
            scores = next
        }
        let oldCenter = (last.start + last.end) / 2
        let candidates = words.indices.filter { index in
            let current = words[index]
            let center = (current.start + current.end) / 2
            // Mutual interior overlap excludes a neighboring short token and
            // partial split tokens. Onset proximity alone confused "with" and
            // "daily" after "who worked with Daly" became "who I worked with daily".
            guard scores[index] >= 2, current.end > current.start,
                  current.start < oldCenter, oldCenter < current.end,
                  last.start < center, center < last.end else { return false }
            return true
        }
        // Do not choose the closest timestamp or the highest-confidence word
        // when repeated/overlapping occurrences support multiple boundaries.
        guard candidates.count == 1, let index = candidates.first else { return nil }
        let next = words.dropFirst(index + 1).first
        if let following {
            guard let next, anchorIdentity(next.text) == anchorIdentity(following.text),
                  abs(next.start - following.start) <= configuration.maximumTimestampDrift else { return nil }
        }
        // Without an independently known following word, a token still inside
        // the old endpoint's span may be the rest of a split owned word.
        // Do not emit it again as new speech, even for an unequal token split.
        if let next, next.start < words[index].end || (following == nil && next.start < last.end) { return nil }
        return index
    }

    private var recoveryWindowLimit: Int {
        min(configuration.maximumRecoveryWindowSamples, configuration.maximumBufferedSamples)
    }

    private func deferAlignment(_ recovery: AlignmentRecovery, snapshot: Snapshot) {
        state.lastDecodedEnd = snapshot.offset + snapshot.audio.count
        // A valid hypothesis that cannot yet advance the crop is still evidence
        // for the next growing window. Invalid/ambiguous alignments are not.
        state.previousTail = configuration.lexicalAgreement ? recovery.agreementTail ?? [] : []
        state.previousTailReuseAgreement = Array(repeating: false, count: state.previousTail.count)
        state.recovering = true
        state.recoveryCandidate = recovery.candidate
        let eligibleAnchors = state.committedAnchors.filter { $0.start >= Double(snapshot.offset) / 16_000 }.count
        onDiagnostic("ownership_recovery:\(recovery.reason.rawValue):samples=\(snapshot.audio.count):originSamples=\(snapshot.offset):anchorCount=\(state.committedAnchors.count):eligibleAnchorCount=\(eligibleAnchors)")
        guard !state.closed else { return }
        state.alignmentDeferrals += 1
        if (state.alignmentDeferrals >= 2 || snapshot.final || snapshot.audio.count >= recoveryWindowLimit),
           beginContinuity(snapshotEnd: snapshot.offset + snapshot.audio.count) {
            return
        }
        if snapshot.final || snapshot.audio.count >= recoveryWindowLimit {
            onDiagnostic("ownership_recovery_exhausted:\(snapshot.final ? "final" : "window_limit")")
            guard !state.closed else { return }
            fail(Failure.ownershipUnresolved)
            return
        }
        // Every accepted attempt has a revision, including deferred observations.
        // Consumers keep their visible prefix/draft and continue accepting audio.
        state.revision += 1
        onUpdate(.init(committedText: state.committedText, tail: state.lastPresentedTail, revision: state.revision))
    }

    // A small non-overlapping segment is the continuity unit, not an utterance.
    // It adds no punctuation or endpoint decisions and runs through pauses.
    private var continuityChunkSamples: Int { min(configuration.windowSamples, 2 * configuration.updateSamples) }

    private func beginContinuity(snapshotEnd: Int) -> Bool {
        guard decodeWithoutTimings != nil, !state.closed else { return false }
        // Use the fence captured when text was committed, not a later guess at
        // where revised words ended. Never skip unowned audio to catch up.
        let frontier = max(state.offset, min(state.committedAudioThrough, snapshotEnd))
        let discard = frontier - state.offset
        guard discard <= state.audio.count else { return false }
        state.audio.removeFirst(discard)
        state.offset = frontier
        state.decodedThroughSample = frontier
        state.lastDecodedEnd = frontier
        state.continuity = true
        state.recovering = false
        state.committedAnchors = []
        state.previousTail = []
        state.previousTailReuseAgreement = []
        state.followingAnchor = nil
        state.recoveryCandidate = nil
        // Retain the best recognized hypothesis for failure/timeout recovery until
        // disjoint decoding has replaced all audio represented by that hypothesis.
        if !state.lastPublishedTail.isEmpty {
            state.continuityRecovery = (state.committedText + state.lastPublishedTail, state.lastPublishedThroughSample)
        }
        state.lastPublishedTail = ""
        state.lastPresentedTail = ""
        state.presentation = WhisperPreviewPresentation()
        state.reuseQuality.recordConcern(.committedTranscriptChanged)
        onDiagnostic("continuity_started:frontierSamples=\(frontier):retainedSamples=\(state.audio.count)")
        return true
    }

    private func acceptContinuity(_ text: String, snapshot: Snapshot) {
        // The decoder saw exactly this disjoint PCM segment. Word timings and
        // earlier lexical revisions cannot gate its delivery or sample coverage.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            state.committedText += join([BufferedTranscriptionWord(text: trimmed, start: 0, end: 0)], after: state.committedText)
        } else {
            state.reuseQuality.recordConcern(.unverifiedEmptyAudio)
        }
        state.audio.removeFirst(snapshot.audio.count)
        state.offset = snapshot.offset + snapshot.audio.count
        state.committedAudioThrough = state.offset
        if let recovery = state.continuityRecovery, state.offset >= recovery.throughSample {
            state.continuityRecovery = nil
        }
        state.lastDecodedEnd = state.offset
        state.decodedThroughSample = state.offset
        state.lastCommitSnapshotEnd = state.offset
        state.revision += 1
        onDiagnostic("continuity_chunk:samples=\(snapshot.audio.count):throughSamples=\(state.offset):characters=\(trimmed.utf16.count)")
        guard !state.closed else { return }
        onUpdate(.init(committedText: state.committedText, tail: "", revision: state.revision))
        if snapshot.final, !state.closed {
            guard state.decodedThroughSample == state.receivedSamples else { close(reason: .incompleteCoverage); return }
            state.finalText = state.committedText
            close()
        }
    }

    /// Quality evidence is independent of the live prefix-commit policy. An
    /// earlier revised word must not erase agreement of later timed occurrences.
    /// Ambiguous repeats never gain evidence by choosing the nearest candidate.
    private func reuseAgreement(for words: [BufferedTranscriptionWord], freshCoverage: Bool) -> [Bool] {
        var previousIndex = -1
        return words.map { word in
            let matches = state.previousTail.indices.filter { index in
                let previous = state.previousTail[index]
                // The same word can absorb trailing silence as context grows.
                // Its unique onset identifies the occurrence; positive speech
                // intervals must still overlap, and all times are validated.
                let overlaps = previous.start == previous.end || word.start == word.end
                    || max(previous.start, word.start) < min(previous.end, word.end)
                return anchorIdentity(previous.text) == anchorIdentity(word.text)
                    && abs(previous.start - word.start) <= configuration.maximumTimestampDrift
                    && overlaps
            }
            guard matches.count == 1, let index = matches.first, index > previousIndex else { return false }
            previousIndex = index
            // An identical stop snapshot may retain prior independent evidence,
            // but two decodes of the same PCM cannot create that evidence.
            return freshCoverage || (state.previousTailReuseAgreement.indices.contains(index)
                && state.previousTailReuseAgreement[index])
        }
    }

    private func recordReuseQuality(_ words: [BufferedTranscriptionWord], agreement: [Bool]) {
        let supportedSpan = Double(configuration.rightContextSamples + configuration.updateSamples) / 16_000
        for (index, word) in words.enumerated() {
            let agreed = agreement[index]
            state.reuseQuality.committedWords += 1
            if agreed {
                state.reuseQuality.agreedWords += 1
                state.reuseQuality.currentUnagreedStart = nil
                state.reuseQuality.currentUnagreedEnd = nil
            } else {
                state.reuseQuality.unagreedWords += 1
                // Carry unsupported runs across commitment batches; only an
                // independently agreed word resets this provisional bound.
                state.reuseQuality.currentUnagreedStart = min(state.reuseQuality.currentUnagreedStart ?? word.start, word.start)
                state.reuseQuality.currentUnagreedEnd = max(state.reuseQuality.currentUnagreedEnd ?? word.end, word.end)
                let span = (state.reuseQuality.currentUnagreedEnd ?? word.end) - (state.reuseQuality.currentUnagreedStart ?? word.start)
                state.reuseQuality.maximumUnagreedSpan = max(state.reuseQuality.maximumUnagreedSpan, span)
                if span > supportedSpan { state.reuseQuality.recordConcern(.unagreedContextTooLong) }
                if word.start == word.end,
                   word.text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                    state.reuseQuality.recordConcern(.unsupportedWordTiming)
                }
            }
            guard let confidence = word.confidence else {
                state.reuseQuality.missingConfidence += 1
                state.reuseQuality.recordConcern(.missingConfidence)
                continue
            }
            guard confidence.isFinite, (0...1).contains(confidence) else {
                state.reuseQuality.invalidConfidence += 1
                state.reuseQuality.recordConcern(.invalidConfidence)
                continue
            }
            state.reuseQuality.minimumConfidence = min(state.reuseQuality.minimumConfidence ?? confidence, confidence)
            let floor = agreed ? ReusePolicy.agreedConfidenceFloor : ReusePolicy.unagreedConfidenceFloor
            if confidence < floor {
                state.reuseQuality.lowConfidence += 1
                let evidence = "start=\(word.start),end=\(word.end),confidence=\(confidence),agreed=\(agreed)"
                if state.reuseQuality.firstLowConfidenceEvidence == nil { state.reuseQuality.firstLowConfidenceEvidence = evidence }
                state.reuseQuality.lastLowConfidenceEvidence = evidence
                state.reuseQuality.recordConcern(.lowConfidence)
            }
        }
    }

    private func wordsAgree(_ previous: BufferedTranscriptionWord, _ current: BufferedTranscriptionWord) -> Bool {
        let sameWord = configuration.lexicalAgreement
            ? agreementIdentity(previous.text) == agreementIdentity(current.text)
            : previous.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.elementsEqual(
                current.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
        return sameWord
            && abs(previous.start - current.start) <= configuration.maximumTimestampDrift
            && abs(previous.end - current.end) <= configuration.maximumTimestampDrift
    }

    private func maturePrefixWithStableSeam(_ words: [BufferedTranscriptionWord], matureCount: Int) -> Int {
        guard configuration.lexicalAgreement, matureCount > 0,
              matureCount < words.count, matureCount < state.previousTail.count else { return 0 }
        // Compare exactly the endpoint and next position, never search for a
        // nearby repeated word. Both observations must contain real timed words;
        // standalone punctuation cannot establish the new ownership boundary.
        for index in (matureCount - 1)...matureCount {
            let previous = state.previousTail[index]
            let current = words[index]
            guard previous.end > previous.start, current.end > current.start,
                  previous.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
                  current.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
                  wordsAgree(previous, current) else { return 0 }
        }
        return matureCount
    }

    private func agreementIdentity(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A hyphen can be a numeric sign. Do not treat '-1' and '1' as
        // cosmetic variants when freezing new speech. Internal punctuation
        // (can't/cant, decimal points) and standalone punctuation also survive.
        let edges = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-#%٪‰‱'’′″"))
            .union(.whitespacesAndNewlines)
        var lexical = trimmed[...]
        while let first = lexical.first, first.unicodeScalars.allSatisfy(edges.contains) {
            if (first == "." || first == ","), lexical.dropFirst().first?.isNumber == true { break }
            lexical.removeFirst()
        }
        while let last = lexical.last, last.unicodeScalars.allSatisfy(edges.contains) { lexical.removeLast() }
        return lexical.isEmpty ? trimmed : lexical.lowercased()
    }

    private func anchorIdentity(_ text: String) -> String {
        // Already committed punctuation/case cannot be rewritten. Ignore those
        // differences only when finding its timed occurrence in a fresh decode.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Adornment may alternate punctuation and spaces ("- Hey,").
        // Trim their union at the edges only; internal punctuation stays lexical.
        let lexical = trimmed.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)).lowercased()
        return lexical.isEmpty ? trimmed : lexical
    }

    private func ownershipBoundary(after last: BufferedTranscriptionWord,
                                   before next: BufferedTranscriptionWord?) throws -> Double {
        guard let next else { return last.end }
        if next.start >= last.end { return (last.end + next.start) / 2 }
        let lastCenter = (last.start + last.end) / 2
        let nextCenter = (next.start + next.end) / 2
        guard nextCenter > lastCenter else { throw AlignmentRecovery(reason: .inseparableTimings) }
        return (lastCenter + nextCenter) / 2
    }

    private func join(_ words: some Collection<BufferedTranscriptionWord>, after prefix: String) -> String {
        var text = words.map(\.text).joined()
        // A fresh decoder window can omit the leading word space. Preserve
        // punctuation and scripts normally written without word separators.
        if let first = text.unicodeScalars.first, let last = prefix.unicodeScalars.last,
           Self.usesWordSpaces(first), Self.usesWordSpaces(last) || Self.endsSpacedSentence(prefix) {
            text = " " + text
        }
        return text
    }

    private static func endsSpacedSentence(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last,
              ".,!?;:…)]}\"'»”’،؛؟".unicodeScalars.contains(last),
              let wordEnd = text.unicodeScalars.reversed().first(where: { !CharacterSet.punctuationCharacters.contains($0) }) else { return false }
        return usesWordSpaces(wordEnd)
    }

    private static func usesWordSpaces(_ scalar: Unicode.Scalar) -> Bool {
        guard CharacterSet.alphanumerics.contains(scalar) else { return false }
        // Han, kana, hangul, Thai, Lao, Khmer and Myanmar retain decoder spacing.
        let value = scalar.value
        return !((0x2E80...0x9FFF).contains(value) || (0xAC00...0xD7AF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x20000...0x323AF).contains(value)
            || (0x0E00...0x0EFF).contains(value) || (0x1000...0x109F).contains(value)
            || (0x1780...0x17FF).contains(value))
    }

    private func fail(_ error: Error) {
        // Publish failure before releasing finish waiters so a caller cannot
        // mistake a failed drain for a successfully completed preview.
        state.closed = true
        state.reuseTerminalReason = .transcriptionFailed
        state.finalText = nil
        // A failure handler may reentrantly cancel. Keep these continuations
        // out of close() until that handler has completely delivered failure.
        let waiters = state.waiters
        state.waiters.removeAll()
        onFailure(error)
        close()
        waiters.forEach { $0.resume() }
    }

    private func close(reason: ReuseFallbackReason? = nil) {
        if let reason {
            state.reuseTerminalReason = reason
            state.finalText = nil
        }
        state.closed = true
        state.running = false
        let task = drainTask?.task
        drainTask = nil
        // Cancellation propagates to a backend waiting for its decode permit.
        // Do not await it: an uncooperative decoder must not delay finish.
        // A successful drain may cancel itself here; its result is already
        // committed, and finish waiters are independent tasks.
        task?.cancel()
        state.audio.removeAll()
        let waiters = state.waiters
        state.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
