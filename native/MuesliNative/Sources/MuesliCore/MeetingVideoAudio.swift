import Foundation

/// Maps delayed AEC output back to raw microphone capture positions (16 kHz host clock).
public struct MeetingVideoAudioSpans: Sendable {
    private var spans: [(start: Int64, count: Int)] = []
    public init() {}
    public mutating func append(start: Int64, count: Int) { spans.append((start, count)) }
    public mutating func consume(_ samples: [Int16]) -> [(start: Int64, samples: [Int16])] {
        var result: [(Int64, [Int16])] = []
        var offset = 0
        while offset < samples.count, !spans.isEmpty {
            let count = min(spans[0].count, samples.count - offset)
            result.append((spans[0].start, Array(samples[offset..<(offset + count)])))
            spans[0].start += Int64(count); spans[0].count -= count; offset += count
            if spans[0].count == 0 { spans.removeFirst() }
        }
        return result
    }
}

/// A bounded timestamped mix. Late samples are dropped at their original position,
/// never shifted into a later slot. A single source retains its full amplitude.
public struct MeetingVideoAudioBuffer: Sendable {
    private var mic: [Int64: Int16] = [:]
    private var system: [Int64: Int16] = [:]
    public private(set) var cursor: Int64
    /// Serial microphone delivery closes the audio window through this frame.
    public private(set) var microphoneEndFrame: Int64?
    public init(start: Int64) { cursor = start }
    /// Anchor already-delivered feedback PCM to the first screen frame.
    public mutating func discard(before frame: Int64) {
        guard frame > cursor else { return }
        mic = mic.filter { $0.key >= frame }; system = system.filter { $0.key >= frame }
        cursor = frame
    }
    public mutating func append(_ samples: [Int16], start: Int64, microphone: Bool) {
        for (offset, value) in samples.enumerated() {
            let position = start + Int64(offset)
            guard position >= cursor, position < cursor + 160_000 else { continue }
            if microphone { mic[position] = value } else { system[position] = value }
        }
    }
    /// Serial feedback delivery bounds queued PCM, independently of silent gaps.
    /// Reject an overflowing block without changing samples or its delivery marker.
    public mutating func appendFeedbackMicrophone(_ samples: [Int16], start: Int64) -> Bool {
        var added = 0
        for offset in samples.indices {
            let position = start + Int64(offset)
            if position >= cursor, mic[position] == nil { added += 1 }
            guard mic.count + added <= 160_000 else { return false }
        }
        for (offset, value) in samples.enumerated() {
            let position = start + Int64(offset)
            if position >= cursor { mic[position] = value }
        }
        if !samples.isEmpty {
            microphoneEndFrame = max(microphoneEndFrame ?? cursor, start + Int64(samples.count))
        }
        return true
    }
    public mutating func take(count: Int) -> [Int16] {
        let values = (0..<count).map { offset in
            let position = cursor + Int64(offset)
            return Int16(clamping: Int(mic.removeValue(forKey: position) ?? 0) + Int(system.removeValue(forKey: position) ?? 0))
        }
        cursor += Int64(count)
        return values
    }
}
