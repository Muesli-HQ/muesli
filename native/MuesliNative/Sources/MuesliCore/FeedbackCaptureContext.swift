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
    public var markId: String?
    public var said: String
    /// Consecutive half-open indexes into transcript.words, independent of decoded frame time.
    public var saidRange: FeedbackCaptureWordRange
    public init(index: Int, t: Int64, reason: String, file: String, eventIndex: Int? = nil, markId: String? = nil,
                said: String, saidRange: FeedbackCaptureWordRange) {
        self.index = index; self.t = t; self.reason = reason; self.file = file
        self.markId = markId; self.eventIndex = eventIndex; self.said = said; self.saidRange = saidRange
    }
}
public struct FeedbackCaptureInputGap: Codable, Equatable, Sendable {
    public var t0: Int64, t1: Int64
    public init(t0: Int64, t1: Int64) { self.t0 = t0; self.t1 = t1 }
}
public enum FeedbackCaptureContext {
    public struct Zoom: Sendable {
        public let t0: Int64, t1: Int64
        public let frames: [ZoomFrame]
        public var times: [Int64] { frames.map(\.t) }
        public let playable: ClosedRange<Int64>
        public let failures: [FeedbackCaptureFailure]
        public let words: [FeedbackCaptureTranscript.Span]
        public let estimated: Bool
        public let missing: FeedbackCaptureTranscript.Missing?
        public var said: String { words.map(\.text).joined(separator: " ") }
    }
    public struct ZoomFrame: Sendable {
        public let t: Int64
        public var markIds: [String] = []
        public var eventIndices: [Int] = []
    }
    /// Keep original point clocks and pin identities; never invent boundary points.
    public static func clippedInk(_ stroke: FeedbackCaptureStroke, to range: ClosedRange<Int64>) -> FeedbackCaptureStroke? {
        var clipped = stroke
        clipped.pts = stride(from: 0, to: stroke.pts.count - 2, by: 3).filter { i in
            let (time, overflow) = stroke.t0.addingReportingOverflow(Int64(stroke.pts[i + 2]))
            return !overflow && range.contains(time)
        }.flatMap { Array(stroke.pts[$0...($0 + 2)]) }
        return clipped.pts.isEmpty ? nil : clipped
    }
    public struct ZoomError: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    public static func validateZoomSelector(at: String?, mark: Int?) throws {
        guard (at == nil) != (mark == nil), mark == nil || mark! > 0 else {
            throw ZoomError("Scrawl zoom requires exactly one of --at M:SS or positive --mark N.")
        }
    }
    /// Narration keeps its capture clock; only image sampling is clipped to video.
    public static func zoom(_ m: FeedbackCaptureManifest, at: String? = nil, mark: Int? = nil,
                            videoDurationMs: Int64) throws -> Zoom {
        try validateZoomSelector(at: at, mark: mark)
        guard m.durationMs > 0 else { throw ZoomError("Scrawl has no nonempty span to zoom.") }
        let start: Int64, end: Int64, padding: Int64
        if let at {
            let parts = at.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 2,
                  parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let minutes = Int64(parts[0]), let seconds = Int64(parts[1]), seconds < 60 else {
                throw ZoomError("Scrawl --at must be M:SS with seconds from 00 to 59.")
            }
            let (ms, overflow) = minutes.multipliedReportingOverflow(by: 60_000)
            let (time, additionOverflow) = ms.addingReportingOverflow(seconds * 1000)
            guard !overflow, !additionOverflow, time <= m.durationMs else { throw ZoomError("Scrawl timestamp is outside the capture duration.") }
            start = time; end = time; padding = 2000
        } else {
            guard let mark, let selected = m.marks.first(where: { $0.id == "m\(mark)" }),
                  selected.t0 >= 0, selected.t1 >= selected.t0, selected.t0 <= m.durationMs else {
                throw ZoomError("Scrawl --mark must identify an existing positive mark ID (mN).")
            }
            start = selected.t0; end = min(m.durationMs, selected.t1); padding = 1000
        }
        let t0 = start > padding ? start - padding : 0
        let t1 = m.durationMs - end < padding ? m.durationMs : end + padding
        let offset = m.videoOffsetMs ?? 0
        guard videoDurationMs > 0 else { throw ZoomError("Scrawl zoom has no playable video.") }
        let (videoEnd, overflow) = offset.addingReportingOverflow(videoDurationMs - 1)
        let first = max(t0, max(0, offset)), last = min(t1, overflow ? Int64.max : videoEnd)
        guard t0 < t1, first <= last else { throw ZoomError("Scrawl zoom span has no playable video.") }
        let playable = first...last
        var frames: [ZoomFrame] = [], failures: [FeedbackCaptureFailure] = []
        func reserve(_ time: Int64?, label: String, markId: String? = nil, eventIndex: Int? = nil) {
            guard let time, playable.contains(time) else {
                failures.append(.init(stage: "zoom", message: "Scrawl \(label) omitted: no playable source time.")); return
            }
            if let i = frames.firstIndex(where: { $0.t == time }) {
                if let markId { frames[i].markIds.append(markId) }
                if let eventIndex { frames[i].eventIndices.append(eventIndex) }
            } else if frames.count < 6 {
                frames.append(.init(t: time, markIds: markId.map { [$0] } ?? [], eventIndices: eventIndex.map { [$0] } ?? []))
            } else {
                failures.append(.init(stage: "zoom", message: "Scrawl \(label) omitted: six-frame limit."))
            }
        }
        func distance(_ time: Int64) -> UInt64 { time >= end ? UInt64(time) - UInt64(end) : UInt64(end) - UInt64(time) }
        let selectedMarkId = mark.map { "m\($0)" }
        let marks = m.marks.enumerated().filter { _, item in
            item.id == selectedMarkId || (item.t0 == item.t1 ? item.t0 >= t0 && item.t0 < t1 : item.t0 < t1 && item.t1 > t0)
        }.sorted { a, b in
            let aSelected = a.element.id == selectedMarkId, bSelected = b.element.id == selectedMarkId
            if aSelected != bSelected { return aSelected }
            let da = distance(a.element.t1), db = distance(b.element.t1)
            return da == db ? a.offset < b.offset : da < db
        }
        for (_, item) in marks {
            let ink = item.strokes.filter { m.strokes.indices.contains($0) }
                .compactMap { clippedInk(m.strokes[$0], to: playable) }
            let retainedEnd = ink.compactMap { stroke -> Int64? in
                guard let delta = stroke.pts.last else { return nil }
                return stroke.t0 + Int64(delta) // clippedInk checked addition.
            }.max()
            let time = retainedEnd == nil ? nil : (item.t0 < first || item.t1 > last ? retainedEnd : item.t1)
            reserve(time, label: "mark \(item.id)", markId: item.id)
        }
        let clicks = m.events.enumerated().filter { $0.element.kind == .click && $0.element.t >= t0 && $0.element.t < t1 }
            .sorted { a, b in
                let da = distance(a.element.t), db = distance(b.element.t)
                return da == db ? a.offset < b.offset : da < db
            }
        for (i, click) in clicks { reserve(click.t, label: "click event \(i + 1)", eventIndex: i) }
        let length = last - first, count = length >= 5 ? 6 : Int(length) + 1, divisor = Int64(max(1, count - 1))
        let spare = (0..<count).map { i in
            first + (length / divisor) * Int64(i) + (length % divisor) * Int64(i) / divisor
        }.filter { time in !frames.contains { $0.t == time } }
        let slots = min(6 - frames.count, spare.count)
        for i in 0..<slots {
            let index = slots == 1 ? spare.count / 2 : i * (spare.count - 1) / (slots - 1)
            frames.append(.init(t: spare[index]))
        }
        let transcript = m.transcript ?? .unavailable("Scrawl narration unavailable")
        let words = transcript.words.filter { word in
            word.t0 == word.t1 ? word.t0 >= t0 && word.t0 < t1 : word.t0 < t1 && word.t1 > t0
        }
        return Zoom(t0: t0, t1: t1, frames: frames.sorted { $0.t < $1.t }, playable: playable, failures: failures,
                    words: words, estimated: transcript.estimated, missing: transcript.missing)
    }
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
        public var markIds: [String] = []
    }
    public static func budget(durationMs: Int64) -> Int {
        6 + Int(min(6, max(0, (Double(durationMs) - 40_000) / 20_000).rounded(.up)))
    }
    private static func change(_ a: Thumbnail, _ b: Thumbnail) -> Double {
        guard !a.luma.isEmpty, a.luma.count == b.luma.count else { return 1 }
        return Double(zip(a.luma, b.luma).filter { abs(Int($0) - Int($1)) > 16 }.count) / Double(a.luma.count)
    }
    private static func settledSceneChanges(in samples: [Thumbnail]) -> [(anchor: Int64, time: Int64, delta: Double)] {
        guard samples.count >= 4 else { return [] }
        var changes: [(anchor: Int64, time: Int64, delta: Double)] = []
        for i in 1..<(samples.count - 2) {
            let delta = change(samples[i - 1], samples[i])
            if delta > 0.12, change(samples[i], samples[i + 1]) < 0.05, change(samples[i], samples[i + 2]) < 0.05 {
                changes.append((anchor: samples[i].t, time: samples[i + 2].t, delta: delta))
            }
        }
        return changes
    }
    public static func markSplitBeforeStrokeIndices(strokes: [FeedbackCaptureStroke], thumbnails: [Thumbnail]) -> Set<Int> {
        let changes = settledSceneChanges(in: thumbnails.sorted { $0.t < $1.t })
        guard !changes.isEmpty, strokes.count > 1 else { return [] }
        var result: Set<Int> = []
        for index in 1..<strokes.count {
            let previous = strokes[index - 1], current = strokes[index]
            if changes.contains(where: { $0.anchor > previous.t1 && $0.anchor <= current.t1 }) {
                result.insert(index)
            }
        }
        return result
    }
    public static func select(durationMs: Int64, events: [FeedbackCaptureEvent], thumbnails: [Thumbnail], marks: [FeedbackCaptureMark] = []) -> [Candidate] {
        let samples = thumbnails.sorted { $0.t < $1.t }
        guard let first = samples.first, let last = samples.last else { return [] }
        let sceneChanges = settledSceneChanges(in: samples)
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
        for scene in sceneChanges {
            candidates.append(.init(anchor: scene.anchor, time: scene.time,
                reason: "scene_change", eventIndex: nil, score: 40 + 20 * scene.delta))
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
        if !marks.isEmpty {
            var mandatory: [Candidate] = []
            var groupBoxes: [[Double]] = []
            for mark in marks {
                let time = min(last.t, max(first.t, mark.t1))
                let previousMarkTimes = mandatory.last.map { prior in
                    marks.filter { prior.markIds.contains($0.id) }.map(\.t1)
                } ?? []
                let crossedSceneChange = previousMarkTimes.contains { previousTime in
                    sceneChanges.contains { $0.anchor > previousTime && $0.anchor <= time }
                }
                if var prior = mandatory.last,
                   !crossedSceneChange,
                   marks.filter({ prior.markIds.contains($0.id) }).allSatisfy({ retained in
                       regionalChange(nearest(retained.t1), nearest(time), boxes: groupBoxes + [mark.boxNorm]) < 0.05
                   }) {
                    mandatory.removeLast()
                    prior = Candidate(anchor: prior.anchor, time: time, reason: "mark", eventIndex: nil,
                                      score: 100, markIds: prior.markIds + [mark.id])
                    mandatory.append(prior); groupBoxes.append(mark.boxNorm)
                } else {
                    mandatory.append(.init(anchor: mark.t0, time: time, reason: "mark", eventIndex: nil, score: 100, markIds: [mark.id]))
                    groupBoxes = [mark.boxNorm]
                }
            }
            bounded = Array(bounded.filter { candidate in
                !mandatory.contains { abs($0.time - candidate.time) <= 500 && change(nearest($0.time), nearest(candidate.time)) < 0.05 }
            }.sorted { $0.score > $1.score }.prefix(max(0, budget(durationMs: durationMs) - mandatory.count))) + mandatory
        }
        return bounded.sorted {
            $0.time == $1.time ? ($0.eventIndex ?? -1) < ($1.eventIndex ?? -1) : $0.time < $1.time
        }
    }
    private static func regionalChange(_ a: Thumbnail, _ b: Thumbnail, boxes: [[Double]]) -> Double {
        guard a.luma.count == 64 * 36, b.luma.count == a.luma.count else { return change(a, b) }
        var cells: Set<Int> = []
        for box in boxes where box.count == 4 && box.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            let x0 = max(0, min(63, Int(floor(box[0] * 64)) - 1)), x1 = max(0, min(63, Int(ceil(box[2] * 64)) + 1))
            let y0 = max(0, min(35, Int(floor(box[1] * 36)) - 1)), y1 = max(0, min(35, Int(ceil(box[3] * 36)) + 1))
            if x0 <= x1 && y0 <= y1 { for y in y0...y1 { for x in x0...x1 { cells.insert(y * 64 + x) } } }
        }
        guard !cells.isEmpty else { return 1 }
        return Double(cells.filter { abs(Int(a.luma[$0]) - Int(b.luma[$0])) > 16 }.count) / Double(cells.count)
    }
    /// Existing frame links carry shared-mark groups through partial rendering.
    public static func linkMarks(_ m: inout FeedbackCaptureManifest) {
        let files = Set(m.keyframes.map(\.file))
        for index in m.marks.indices {
            if let file = m.marks[index].frame, files.contains(file) { continue }
            m.marks[index].frame = m.keyframes.first { $0.markId == m.marks[index].id }?.file
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
                file: String(format: "frames/frame-%02d.png", index + 1), eventIndex: candidate.eventIndex, markId: candidate.markIds.first,
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
        lines.append("Zoom Scrawl: `muesli-cli captures zoom \(m.id) --at M:SS` shows a moment in detail; use --mark N for mark mN.")
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
            let marks = m.marks.filter { $0.frame == frame.file || $0.id == frame.markId }
            if !marks.isEmpty { line += " " + marks.map { "✎ " + $0.description }.joined(separator: "; ") }
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
        for mark in m.marks where !m.keyframes.contains(where: { $0.file == mark.frame || $0.markId == mark.id }) {
            lines.append("- Mark (\(stamp(mark.t0))) ✎ \(mark.description)")
        }
        let overflow = m.keyframes.dropFirst(12).filter { $0.reason == "mark" }.count
        if overflow > 0 { lines.append("+\(overflow) more marked frames in frames/") }
        for failure in m.failures { lines.append("\(failure.stage): \(failure.message)") }
        return lines.joined(separator: "\n") + "\n"
    }
}
