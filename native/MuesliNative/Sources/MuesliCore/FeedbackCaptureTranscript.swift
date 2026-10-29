import Foundation

public struct FeedbackCaptureTranscript: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable {
        public let t0: Int64, t1: Int64
        public let text: String
        public init(t0: Int64, t1: Int64, text: String) { self.t0 = t0; self.t1 = t1; self.text = text }
    }
    public struct Missing: Codable, Equatable, Sendable { public let reason: String }
    public var source: String
    public var model: String?
    public var text: String
    public var words: [Span]
    public var segments: [Span]
    public var estimated: Bool
    public var missing: Missing?
    public init(source: String, model: String? = nil, text: String, words: [Span], segments: [Span], estimated: Bool) {
        self.source = source; self.model = model; self.text = text
        self.words = words; self.segments = segments; self.estimated = estimated
    }
    public static func unavailable(_ reason: String, source: String = "none", model: String? = nil) -> Self {
        var result = Self(source: source, model: model, text: "", words: [], segments: [], estimated: true)
        result.missing = Missing(reason: reason)
        return result
    }
    public var firstClause: String? {
        let clause = text.split(whereSeparator: { ".,!?;:\n".contains($0) }).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clause.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
    }
    public static func estimatedWords(_ text: String, t0: Int64, t1: Int64) -> [Span] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = words.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        var used = 0
        return words.map { word in
            let start = t0 + Int64(Double(max(0, t1 - t0)) * Double(used) / Double(total))
            used += word.count
            let end = t0 + Int64(Double(max(0, t1 - t0)) * Double(used) / Double(total))
            return Span(t0: start, t1: end, text: word)
        }
    }
    /// Return a sample boundary at the centre of the quietest 50 ms window in
    /// the last second. The reader keeps both sides, including silent samples.
    public static func quietCut(samples: [Float], sampleRate: Double) -> Int {
        let width = max(1, Int(sampleRate * 0.05))
        guard samples.count > Int(sampleRate), sampleRate > 0 else { return samples.count }
        let start = samples.count - Int(sampleRate)
        var best = samples.count, energy = Double.infinity
        for index in stride(from: start, through: samples.count - width, by: width) {
            let value = samples[index..<(index + width)].reduce(0.0) { $0 + Double($1) * Double($1) }
            if value < energy { energy = value; best = index + width / 2 }
        }
        return best
    }
}
