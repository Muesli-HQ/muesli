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
        var maximumBufferedSamples = 480_000
        /// Only suppress an entirely silent window. Quiet speech is not trimmed.
        var silenceRMS: Float = 0.0001
    }

    enum Failure: Error, LocalizedError {
        case audioOverrun, invalidTimings, cannotAdvance
        var errorDescription: String? {
            switch self {
            case .audioOverrun: return "Live transcription could not keep up. The recording is still available for final transcription."
            case .invalidTimings: return "Live transcription returned unusable word timing."
            case .cannotAdvance: return "Live transcription could not safely advance its audio window."
            }
        }
    }

    private struct State {
        var audio: [Float] = []
        var offset = 0
        var lastDecodedEnd = 0
        var ownedUntil: Double = 0
        var committedText = ""
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
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        precondition(configuration.minimumSamples > 0 && configuration.updateSamples > 0)
        precondition(configuration.windowSamples > configuration.minimumSamples)
        precondition(configuration.rightContextSamples > 0 && configuration.leftContextSamples >= 0)
        precondition(configuration.rightContextSamples + configuration.leftContextSamples < configuration.windowSamples)
        precondition(configuration.maximumBufferedSamples >= configuration.windowSamples)
        self.configuration = configuration
        self.decode = decode
        self.onUpdate = onUpdate
        self.onFailure = onFailure
    }

    func enqueue(_ samples: [Float]) {
        synchronized {
            guard !state.closed, !state.finishing, !samples.isEmpty else { return }
            guard samples.count <= configuration.maximumBufferedSamples - state.audio.count,
                  samples.allSatisfy(\.isFinite) else {
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
            let count = min(state.audio.count, configuration.windowSamples)
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
                    try accept(result, snapshot: snapshot)
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
        let base = Double(snapshot.offset) / 16_000
        let words = result.words.filter { base + ($0.start + $0.end) / 2 > state.ownedUntil }
        let rolls = snapshot.audio.count == configuration.windowSamples && !snapshot.final
        var commitCount = snapshot.final ? words.count : 0
        var boundary = base + duration
        var retainFrom = boundary
        if rolls {
            let desired = duration - Double(configuration.rightContextSamples) / 16_000
            commitCount = words.prefix { $0.end <= desired }.count
            if commitCount > 0 {
                let last = words[commitCount - 1]
                let nextStart = commitCount < words.count ? words[commitCount].start : desired
                if nextStart < last.end, commitCount < words.count {
                    // Timestamp spans can overlap. Assign whole words by their
                    // centers, and retain the full next word's audio as context.
                    let next = words[commitCount]
                    let lastCenter = (last.start + last.end) / 2
                    let nextCenter = (next.start + next.end) / 2
                    guard nextCenter > lastCenter else { throw Failure.invalidTimings }
                    boundary = base + (lastCenter + nextCenter) / 2
                } else {
                    boundary = base + (last.end + nextStart) / 2
                }
                retainFrom = min(boundary, base + nextStart)
            } else if words.isEmpty || (words.first?.start ?? 0) >= desired {
                // A silent leading span can advance without committing text;
                // speech near the right edge remains in the retained window.
                boundary = base + desired
                retainFrom = boundary
            } else {
                throw Failure.cannotAdvance
            }
        }
        if commitCount > 0 {
            state.committedText += join(words.prefix(commitCount), after: state.committedText)
        }
        let tail = join(words.dropFirst(commitCount), after: state.committedText)
        state.lastDecodedEnd = snapshot.offset + snapshot.audio.count
        if rolls {
            let discard = Int(retainFrom * 16_000) - configuration.leftContextSamples - state.offset
            guard discard > 0, discard <= state.audio.count else { throw Failure.cannotAdvance }
            state.ownedUntil = boundary
            state.audio.removeFirst(discard)
            state.offset += discard
        }
        state.revision += 1
        onUpdate(.init(committedText: state.committedText, tail: tail, revision: state.revision))
        if snapshot.final { close() }
    }

    private func join(_ words: some Collection<BufferedTranscriptionWord>, after prefix: String) -> String {
        var text = words.map(\.text).joined()
        // A fresh decoder window can omit the leading word space. Preserve
        // punctuation and scripts normally written without word separators.
        if let first = text.unicodeScalars.first, let last = prefix.unicodeScalars.last,
           Self.usesWordSpaces(first), Self.usesWordSpaces(last) {
            text = " " + text
        }
        return text
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
