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
    public init(start: Int64) { cursor = start }
    public mutating func append(_ samples: [Int16], start: Int64, microphone: Bool) {
        for (offset, value) in samples.enumerated() {
            let position = start + Int64(offset)
            guard position >= cursor, position < cursor + 160_000 else { continue }
            if microphone { mic[position] = value } else { system[position] = value }
        }
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
