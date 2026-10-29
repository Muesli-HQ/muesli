import Foundation

public struct FeedbackCaptureWordRange: Codable, Equatable, Sendable {
    public var from: Int, to: Int
    public init(from: Int, to: Int) { self.from = from; self.to = to }
}
public struct FeedbackCaptureKeyframe: Codable, Equatable, Sendable {
    public var index: Int
    public var t: Int64
    public var reason: String
    public var file: String
    public var eventIndex: Int?
    public var said: String
    /// Consecutive half-open indexes into transcript.words, independent of decoded frame time.
    public var saidRange: FeedbackCaptureWordRange
    public init(index: Int, t: Int64, reason: String, file: String, eventIndex: Int? = nil,
                said: String, saidRange: FeedbackCaptureWordRange) {
        self.index = index; self.t = t; self.reason = reason; self.file = file
        self.eventIndex = eventIndex; self.said = said; self.saidRange = saidRange
    }
}
public struct FeedbackCaptureInputGap: Codable, Equatable, Sendable {
    public var t0: Int64, t1: Int64
    public init(t0: Int64, t1: Int64) { self.t0 = t0; self.t1 = t1 }
}
public enum FeedbackCaptureContext {
    public struct Thumbnail: Equatable, Sendable {
        public let t: Int64
        public let luma: [UInt8]
        public init(t: Int64, luma: [UInt8]) { self.t = t; self.luma = luma }
    }
    public struct Candidate: Equatable, Sendable {
        public let anchor: Int64
        public let time: Int64
        public let reason: String
        public let eventIndex: Int?
        public let score: Double
    }
    public static func budget(durationMs: Int64) -> Int {
        6 + Int(min(6, max(0, (Double(durationMs) - 40_000) / 20_000).rounded(.up)))
    }
    private static func change(_ a: Thumbnail, _ b: Thumbnail) -> Double {
        guard !a.luma.isEmpty, a.luma.count == b.luma.count else { return 1 }
        return Double(zip(a.luma, b.luma).filter { abs(Int($0) - Int($1)) > 16 }.count) / Double(a.luma.count)
    }
    public static func select(durationMs: Int64, events: [FeedbackCaptureEvent], thumbnails: [Thumbnail]) -> [Candidate] {
        let samples = thumbnails.sorted { $0.t < $1.t }
        guard let first = samples.first, let last = samples.last else { return [] }
        func nearest(_ time: Int64) -> Thumbnail {
            samples.min { abs($0.t - time) < abs($1.t - time) }!
        }
        var candidates = [Candidate(anchor: first.t, time: first.t, reason: "initial", eventIndex: nil, score: 1)]
        for (index, event) in events.enumerated() {
            let time = min(last.t, max(first.t, event.end + 250))
            let before = samples.last { $0.t < event.t } ?? first
            let delta = change(before, nearest(time))
            candidates.append(.init(anchor: event.t, time: time,
                reason: event.kind == .scroll ? "scene_change" : event.kind.rawValue, eventIndex: index, score: 60 + 30 * delta))
        }
        // A scene must change and remain settled for two further samples (about 500 ms).
        if samples.count >= 4 {
            for i in 1..<(samples.count - 2) {
                let delta = change(samples[i - 1], samples[i])
                if delta > 0.12, change(samples[i], samples[i + 1]) < 0.05, change(samples[i], samples[i + 2]) < 0.05 {
                    candidates.append(.init(anchor: samples[i].t, time: samples[i + 2].t,
                        reason: "scene_change", eventIndex: nil, score: 40 + 20 * delta))
                }
            }
        }
        let ranked = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.time != $1.time { return $0.time < $1.time }
            return ($0.eventIndex ?? -1) < ($1.eventIndex ?? -1)
        }
        var selected: [Candidate] = []
        for candidate in ranked {
            let duplicate = selected.contains { prior in
                // Separate actions retain their references, even on an unchanged screen.
                if prior.eventIndex != nil && candidate.eventIndex != nil { return false }
                return abs(prior.time - candidate.time) <= 500 && change(nearest(prior.time), nearest(candidate.time)) < 0.05
            }
            if !duplicate { selected.append(candidate) }
        }
        // Retain the initial view when it has not already coalesced with an action.
        let initial = selected.first { $0.reason == "initial" }
        var bounded = Array(selected.filter { $0.reason != "initial" }.prefix(budget(durationMs: durationMs) - (initial == nil ? 0 : 1)))
        if let initial { bounded.append(initial) }
        return bounded.sorted {
            $0.time == $1.time ? ($0.eventIndex ?? -1) < ($1.eventIndex ?? -1) : $0.time < $1.time
        }
    }
    public static func partition(transcript: FeedbackCaptureTranscript, anchors: [Int64]) -> [FeedbackCaptureWordRange] {
        guard !anchors.isEmpty else { return [] }
        let words = transcript.words
        let segmentStarts = Set(transcript.segments.compactMap { segment in words.firstIndex { $0.t0 >= segment.t0 } })
        var boundaries = [0]
        for anchor in anchors.dropFirst() {
            var boundary = words.firstIndex { $0.t0 >= anchor || $0.t1 > anchor } ?? words.count
            if boundary < words.count {
                while boundary > boundaries.last! {
                    let previous = words[boundary - 1]
                    if previous.text.last.map({ ".,!?;:".contains($0) }) == true || segmentStarts.contains(boundary)
                        || words[boundary].t0 - previous.t1 >= 1500 { break }
                    boundary -= 1
                }
            }
            boundaries.append(max(boundaries.last!, boundary))
        }
        boundaries.append(words.count)
        return zip(boundaries, boundaries.dropFirst()).map { .init(from: $0, to: $1) }
    }
    public static func keyframes(_ candidates: [Candidate], transcript: FeedbackCaptureTranscript?) -> [FeedbackCaptureKeyframe] {
        let transcript = transcript ?? .unavailable("narration unavailable")
        let anchorOrder = candidates.indices.sorted {
            let left = candidates[$0].anchor, right = candidates[$1].anchor
            return left == right ? $0 < $1 : left < right
        }
        let anchorRanges = partition(transcript: transcript, anchors: anchorOrder.map { candidates[$0].anchor })
        var rangesByDisplayOrder = Array(repeating: FeedbackCaptureWordRange(from: 0, to: 0), count: candidates.count)
        for (rangeIndex, candidateIndex) in anchorOrder.enumerated() {
            rangesByDisplayOrder[candidateIndex] = anchorRanges[rangeIndex]
        }
        return candidates.enumerated().map { index, candidate in
            let range = rangesByDisplayOrder[index]
            return .init(index: index + 1, t: candidate.time, reason: candidate.reason,
                file: String(format: "frames/frame-%02d.png", index + 1), eventIndex: candidate.eventIndex,
                said: transcript.words[range.from..<range.to].map(\.text).joined(separator: " "), saidRange: range)
        }
    }
    private static func stamp(_ t: Int64) -> String {
        String(format: "%d:%02d", max(0, t) / 60_000, (max(0, t) / 1000) % 60)
    }
    private static func description(_ event: FeedbackCaptureEvent) -> String {
        switch event.kind {
        case .click: String(format: "[clicked x %.2f, y %.2f]", event.x, event.y)
        case .drag: String(format: "[dragged x %.2f, y %.2f to x %.2f, y %.2f]", event.x, event.y, event.x1 ?? event.x, event.y1 ?? event.y)
        case .scroll: String(format: "[scrolled x %.2f, y %.2f, dx %.1f, dy %.1f]", event.x, event.y, event.dx ?? 0, event.dy ?? 0)
        }
    }
    public static func unillustratedNarration(_ m: FeedbackCaptureManifest) -> (text: String, estimated: Bool, missingReason: String?) {
        let transcript = m.transcript
        let words = transcript?.words ?? []
        var illustrated: Set<Int> = []
        for frame in m.keyframes {
            let from = min(words.count, max(0, frame.saidRange.from)), to = min(words.count, max(0, frame.saidRange.to))
            if from <= to { illustrated.formUnion(from..<to) }
        }
        let text = words.isEmpty ? (transcript?.text ?? "")
            : words.enumerated().filter { !illustrated.contains($0.offset) }.map(\.element.text).joined(separator: " ")
        return (text, transcript?.estimated == true && transcript?.missing == nil, transcript?.missing?.reason)
    }
    public static func summary(_ m: FeedbackCaptureManifest, bundle: URL) -> String {
        func path(_ relative: String) -> String { bundle.appendingPathComponent(relative).path }
        var lines = ["[muesli Scrawl \(stamp(m.durationMs)) · \(m.target.appName) · \(bundle.path)]",
            "Manifest: \(path("capture.json"))"]
        if let sheet = m.contactSheet {
            lines.append("Contact sheet: \(path(sheet))")
            lines.append("Open the contact sheet and frames before changing anything: the words make sense on the images.")
        }
        if let video = m.video { lines.append("Video: \(path(video))") }
        if let audio = m.audio { lines.append("Narration: \(path(audio))") }
        if let reason = m.transcript?.missing?.reason { lines.append("No transcript: \(reason)") }
        else if m.transcript == nil { lines.append("No transcript: narration unavailable") }
        var referenced: Set<Int> = []
        for frame in m.keyframes {
            var line = "- #\(frame.index) (\(stamp(frame.t)))"
            if let index = frame.eventIndex, m.events.indices.contains(index) {
                line += " " + description(m.events[index]); referenced.insert(index)
            }
            if !frame.said.isEmpty { line += " “\(frame.said)”" }
            line += " — \(path(frame.file))"
            lines.append(line)
        }
        let narration = unillustratedNarration(m)
        if narration.estimated {
            lines.append("Estimated timing: word-to-image matches use approximate timestamps.")
        }
        if !narration.text.isEmpty { lines.append("Unillustrated narration: “\(narration.text)”") }
        for (index, event) in m.events.enumerated() where !referenced.contains(index) {
            lines.append("- Event (\(stamp(event.t))) \(description(event))")
        }
        for failure in m.failures { lines.append("\(failure.stage): \(failure.message)") }
        return lines.joined(separator: "\n") + "\n"
    }
}
