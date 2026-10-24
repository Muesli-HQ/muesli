import Foundation

/// Word times are relative to the start of the PCM supplied to the decoder.
struct BufferedTranscriptionWord: Sendable, Equatable {
    let text: String
    let start: Double
    let end: Double
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
            aligned.append(.init(text: String(text[cursor..<range.upperBound]), start: word.start, end: word.end))
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

/// A preview session only: the retained recording remains the final authority.
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
    }
    private struct AlignmentRecovery: Error {
        let reason: RecoveryReason
        var candidate: [BufferedTranscriptionWord]? = nil
    }

    private struct State {
        var audio: [Float] = []
        var offset = 0
        var lastDecodedEnd = 0
        var ownedUntil: Double = 0
        var committedText = ""
        var committedAnchors: [BufferedTranscriptionWord] = []
        var previousTail: [BufferedTranscriptionWord] = []
        var lastPublishedTail = ""
        var recovering = false
        var recoveryCandidate: [BufferedTranscriptionWord]?
        var followingAnchor: BufferedTranscriptionWord?
        var revision: UInt64 = 0
        var receivedSamples = 0
        var decodeCount = 0
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
    private let configuration: Configuration
    private let decode: @Sendable ([Float]) async throws -> BufferedTranscriptionWindow
    private let onUpdate: @Sendable (BufferedTranscriptionUpdate) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let onDiagnostic: @Sendable (String) -> Void

    var diagnostics: Diagnostics {
        synchronized {
            Diagnostics(receivedSamples: state.receivedSamples, decodeCount: state.decodeCount,
                        revision: state.revision, closed: state.closed)
        }
    }

    init(
        configuration: Configuration = .init(),
        decode: @escaping @Sendable ([Float]) async throws -> BufferedTranscriptionWindow,
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
        self.configuration = configuration
        self.decode = decode
        self.onUpdate = onUpdate
        self.onFailure = onFailure
        self.onDiagnostic = onDiagnostic
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
        synchronized { close() }
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

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func startIfNeeded() {
        guard !state.running, !state.closed else { return }
        guard state.finishing || state.audio.count >= configuration.minimumSamples else { return }
        guard state.finishing || state.offset + state.audio.count - state.lastDecodedEnd >= configuration.updateSamples else { return }
        state.running = true
        Task { await drain() }
    }

    private func snapshot() -> Snapshot? {
        synchronized {
            guard !state.closed else { state.running = false; return nil }
            if state.finishing && state.audio.isEmpty { close(); return nil }
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
                    result = try await decode(snapshot.audio)
                }
                try synchronized {
                    guard !state.closed else { return }
                    // accept can update anchors before discovering that a roll
                    // cannot advance. Recovery must restore the entire proposal,
                    // including PCM, before deferring this observation.
                    let checkpoint = state
                    do {
                        try accept(result, snapshot: snapshot)
                    } catch let recovery as AlignmentRecovery {
                        state = checkpoint
                        deferAlignment(recovery, snapshot: snapshot)
                    }
                }
            } catch {
                synchronized { if !state.closed { fail(error) } }
            }
        }
    }

    private func accept(_ result: BufferedTranscriptionWindow, snapshot: Snapshot) throws {
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
        if result.words.isEmpty && (!state.committedAnchors.isEmpty || !state.lastPublishedTail.isEmpty) {
            throw AlignmentRecovery(reason: .emptyHypothesis)
        }
        let base = Double(snapshot.offset) / 16_000
        let absoluteWords = result.words.map {
            BufferedTranscriptionWord(text: $0.text, start: base + $0.start, end: base + $0.end)
        }
        let unownedStart = try unownedStart(in: absoluteWords, base: base)
        let words = Array(absoluteWords.dropFirst(unownedStart))
        let matureUntil = base + duration - Double(configuration.rightContextSamples) / 16_000
        let matureCount = words.prefix { $0.end <= matureUntil }.count
        var agreementCount = 0
        for (previous, current) in zip(state.previousTail, words) {
            // Position and time must agree as well as spelling. Repeated words
            // remain separate occurrences; punctuation and case stay revisable
            // until both consecutive hypotheses agree exactly.
            guard previous.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.elementsEqual(
                current.text.trimmingCharacters(in: .whitespacesAndNewlines).utf16),
                abs(previous.start - current.start) <= configuration.maximumTimestampDrift,
                abs(previous.end - current.end) <= configuration.maximumTimestampDrift else { break }
            agreementCount += 1
        }
        // A full encoder window must advance even after a coalesced first decode.
        // Its existing right-context policy remains the bounded fallback; shorter
        // windows now freeze agreed prefixes instead of rewriting whole sentences.
        let commitCount = snapshot.final ? words.count : rolls ? matureCount : min(matureCount, agreementCount)
        var retainFrom = base + duration
        if commitCount > 0 {
            let committed = Array(words.prefix(commitCount))
            let last = committed[committed.count - 1]
            let next = words.dropFirst(commitCount).first
            state.ownedUntil = try ownershipBoundary(after: last, before: next)
            // Keep the last owned word available as a timing anchor at rollover,
            // including when a long word starts before the usual left context.
            retainFrom = min(state.ownedUntil, next?.start ?? state.ownedUntil,
                             last.start)
            state.committedText += join(committed, after: state.committedText)
            state.committedAnchors = Array((state.committedAnchors + committed).suffix(4))
            if rolls, (next?.start ?? matureUntil) >= matureUntil,
               last.end + Double(configuration.leftContextSamples) / 16_000 + configuration.maximumTimestampDrift < matureUntil {
                // A long decoded silence after the last word needs no lexical
                // anchor. Retain its right context and own only the silent lead.
                state.ownedUntil = matureUntil
                retainFrom = matureUntil
            }
        } else if rolls {
            if words.isEmpty || (words.first?.start ?? base) >= matureUntil {
                // There is no unowned speech in this leading span. Its old anchors
                // may leave the retained PCM; the absolute time boundary then owns it.
                state.ownedUntil = max(state.ownedUntil, matureUntil)
                retainFrom = matureUntil
            } else if let lastOwned = state.committedAnchors.last {
                // A fractional rolling window can end while the next word
                // straddles the maturity cutoff. Previously owned audio still
                // provides safe progress; no additional commitment is required.
                retainFrom = min(state.ownedUntil, words.first?.start ?? state.ownedUntil, lastOwned.start)
            } else {
                throw AlignmentRecovery(reason: .noRollProgress)
            }
        }
        let tailWords = Array(words.dropFirst(commitCount))
        let tail = join(tailWords, after: state.committedText)
        // Preserve agreement across rolls in absolute audio time.
        state.previousTail = tailWords
        state.lastPublishedTail = tail
        state.followingAnchor = tailWords.first
        state.lastDecodedEnd = snapshot.offset + snapshot.audio.count
        if rolls {
            let discard = Int(retainFrom * 16_000) - configuration.leftContextSamples - state.offset
            guard discard > 0, discard <= state.audio.count else { throw AlignmentRecovery(reason: .noRollProgress) }
            state.audio.removeFirst(discard)
            state.offset += discard
            let newBase = Double(state.offset) / 16_000
            state.committedAnchors.removeAll { $0.end < newBase }
        }
        if state.recovering {
            state.recovering = false
            state.recoveryCandidate = nil
            onDiagnostic("ownership_recovered:samples=\(snapshot.audio.count)")
            guard !state.closed else { return }
        }
        state.revision += 1
        onUpdate(.init(committedText: state.committedText, tail: tail, revision: state.revision))
        if snapshot.final { close() }
    }

    /// Locate already-owned words using ordered, timed anchors, not textual
    /// overlap removal. Refresh their positions on every decode so small timing
    /// jitter cannot push an owned repeated word back into the draft tail.
    private func unownedStart(in words: [BufferedTranscriptionWord], base: Double) throws -> Int {
        guard !state.committedAnchors.isEmpty else {
            return words.prefix { ($0.start + $0.end) / 2 <= state.ownedUntil }.count
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
                    matchedIndex = index
                    break
                }
                throw AlignmentRecovery(reason: .changedAnchor, candidate: candidate)
            }
        }
        guard let matchedIndex else { throw AlignmentRecovery(reason: .missingAnchor) }
        let lastCurrent = words[matchedIndex]
        state.committedAnchors = Array(words.prefix(matchedIndex + 1).suffix(4))
        state.ownedUntil = try ownershipBoundary(after: lastCurrent,
                                               before: words.dropFirst(matchedIndex + 1).first)
        return matchedIndex + 1
    }

    private var recoveryWindowLimit: Int {
        min(configuration.maximumRecoveryWindowSamples, configuration.maximumBufferedSamples)
    }

    private func deferAlignment(_ recovery: AlignmentRecovery, snapshot: Snapshot) {
        state.lastDecodedEnd = snapshot.offset + snapshot.audio.count
        state.previousTail = [] // Fresh two-hypothesis agreement after recovery.
        state.recovering = true
        state.recoveryCandidate = recovery.candidate
        onDiagnostic("ownership_recovery:\(recovery.reason.rawValue):samples=\(snapshot.audio.count)")
        guard !state.closed else { return }
        if snapshot.final || snapshot.audio.count >= recoveryWindowLimit {
            onDiagnostic("ownership_recovery_exhausted:\(snapshot.final ? "final" : "window_limit")")
            guard !state.closed else { return }
            fail(Failure.ownershipUnresolved)
            return
        }
        // Every accepted attempt has a revision, including deferred observations.
        // Consumers keep their visible prefix/draft and continue accepting audio.
        state.revision += 1
        onUpdate(.init(committedText: state.committedText, tail: state.lastPublishedTail, revision: state.revision))
    }

    private func anchorIdentity(_ text: String) -> String {
        // Already committed punctuation/case cannot be rewritten. Ignore those
        // differences only when finding its timed occurrence in a fresh decode.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lexical = trimmed.trimmingCharacters(in: .punctuationCharacters).lowercased()
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
        // A failure handler may reentrantly cancel. Keep these continuations
        // out of close() until that handler has completely delivered failure.
        let waiters = state.waiters
        state.waiters.removeAll()
        onFailure(error)
        close()
        waiters.forEach { $0.resume() }
    }

    private func close() {
        state.closed = true
        state.running = false
        state.audio.removeAll()
        let waiters = state.waiters
        state.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
