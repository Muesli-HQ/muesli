import FluidAudio
import Foundation
import MuesliCore

struct ReconciledTranscriptInputs {
    let micSegments: [SpeechSegment]
    let systemSegments: [SpeechSegment]
    let diarizationSegments: [TimedSpeakerSegment]?
    let micDiarizationSegments: [TimedSpeakerSegment]?
}

enum TranscriptReconciler {
    private enum Source {
        case mic
        case system
    }

    private struct WindowCandidate {
        let source: Source
        let segment: SpeechSegment
        let paddedStart: TimeInterval
        let paddedEnd: TimeInterval
    }

    private struct OverlapWindow {
        let start: TimeInterval
        let end: TimeInterval
        let micTurns: [SpeechSegment]
        let systemTurns: [SpeechSegment]
    }

    private static let overlapPaddingSeconds: TimeInterval = 0.25
    private static let turnMergeGapSeconds: TimeInterval = 0.35

    static func reconcile(
        micTurns: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        micDiarizationSegments: [TimedSpeakerSegment]? = nil
    ) -> ReconciledTranscriptInputs {
        let normalizedMicTurns = mergeReadableSegments(sortedSegments(micTurns), diarizationSegments: micDiarizationSegments)
        let normalizedSystemTurns = sortedSegments(dedupeSystemSegments(systemSegments))
        let windows = buildWindows(
            micTurns: normalizedMicTurns,
            systemTurns: normalizedSystemTurns
        )

        var keptMicTurns: [SpeechSegment] = []
        var keptSystemTurns: [SpeechSegment] = []

        for window in windows {
            let reconciledWindow = reconcile(window, micDiarizationSegments: micDiarizationSegments)
            keptMicTurns.append(contentsOf: reconciledWindow.micTurns)
            keptSystemTurns.append(contentsOf: reconciledWindow.systemTurns)
        }

        return ReconciledTranscriptInputs(
            micSegments: sortedSegments(keptMicTurns),
            systemSegments: sortedSegments(keptSystemTurns),
            diarizationSegments: diarizationSegments,
            micDiarizationSegments: micDiarizationSegments
        )
    }

    private static func reconcile(
        _ window: OverlapWindow,
        micDiarizationSegments: [TimedSpeakerSegment]?
    ) -> OverlapWindow {
        let mergedMicTurns = mergeReadableSegments(window.micTurns, diarizationSegments: micDiarizationSegments)
        let keptSystemTurns = sortedSegments(dedupeSystemSegments(window.systemTurns))

        guard !mergedMicTurns.isEmpty, !keptSystemTurns.isEmpty else {
            return OverlapWindow(
                start: window.start,
                end: window.end,
                micTurns: mergedMicTurns,
                systemTurns: keptSystemTurns
            )
        }

        let keptMicTurns = mergeReadableSegments(
            mergedMicTurns.filter { shouldKeepMicTurn($0, overlappingSystemTurns: keptSystemTurns) },
            diarizationSegments: micDiarizationSegments
        )

        return OverlapWindow(
            start: window.start,
            end: window.end,
            micTurns: keptMicTurns,
            systemTurns: keptSystemTurns
        )
    }

    private static func buildWindows(
        micTurns: [SpeechSegment],
        systemTurns: [SpeechSegment]
    ) -> [OverlapWindow] {
        let candidates =
            micTurns.map { makeCandidate(source: .mic, segment: $0) } +
            systemTurns.map { makeCandidate(source: .system, segment: $0) }

        let orderedCandidates = candidates.sorted { lhs, rhs in
            if lhs.paddedStart == rhs.paddedStart {
                return lhs.paddedEnd < rhs.paddedEnd
            }
            return lhs.paddedStart < rhs.paddedStart
        }

        var windows: [OverlapWindow] = []
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval = 0
        var currentMicTurns: [SpeechSegment] = []
        var currentSystemTurns: [SpeechSegment] = []

        func flushCurrentWindow() {
            guard let currentStart else { return }
            windows.append(
                OverlapWindow(
                    start: currentStart,
                    end: currentEnd,
                    micTurns: sortedSegments(currentMicTurns),
                    systemTurns: sortedSegments(currentSystemTurns)
                )
            )
            currentMicTurns.removeAll(keepingCapacity: false)
            currentSystemTurns.removeAll(keepingCapacity: false)
        }

        for candidate in orderedCandidates {
            if currentStart != nil {
                if candidate.paddedStart <= currentEnd {
                    currentEnd = max(currentEnd, candidate.paddedEnd)
                } else {
                    flushCurrentWindow()
                    currentStart = candidate.paddedStart
                    currentEnd = candidate.paddedEnd
                }
            } else {
                currentStart = candidate.paddedStart
                currentEnd = candidate.paddedEnd
            }

            switch candidate.source {
            case .mic:
                currentMicTurns.append(candidate.segment)
            case .system:
                currentSystemTurns.append(candidate.segment)
            }
        }

        flushCurrentWindow()
        return windows
    }

    private static func makeCandidate(source: Source, segment: SpeechSegment) -> WindowCandidate {
        WindowCandidate(
            source: source,
            segment: segment,
            paddedStart: segment.start - overlapPaddingSeconds,
            paddedEnd: segment.end + overlapPaddingSeconds
        )
    }

    /// Preserve-first: keep all non-empty mic turns. System capture is the
    /// remote source of truth; deleting a real local turn is irreversible.
    private static func shouldKeepMicTurn(
        _ micTurn: SpeechSegment,
        overlappingSystemTurns: [SpeechSegment]
    ) -> Bool {
        guard !overlappingSystemTurns.isEmpty else { return true }
        return !normalizedText(micTurn.text).isEmpty
    }

    /// Merges adjacent, close-together segments into single readable turns.
    /// When `diarizationSegments` identifies more than one distinct speaker,
    /// a merge is refused across a detected speaker change — otherwise two
    /// room speakers' turns could combine into one SpeechSegment, and
    /// downstream speaker attribution would credit all of that text to
    /// whichever speaker has the most overlap (see TranscriptFormatter).
    private static func mergeReadableSegments(
        _ segments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]? = nil
    ) -> [SpeechSegment] {
        guard !segments.isEmpty else { return [] }

        let orderedSegments = sortedSegments(segments)
        var merged: [SpeechSegment] = [orderedSegments[0]]
        var mergedSpeaker = dominantSpeaker(for: orderedSegments[0], in: diarizationSegments)

        for segment in orderedSegments.dropFirst() {
            guard let previous = merged.last else {
                merged.append(segment)
                mergedSpeaker = dominantSpeaker(for: segment, in: diarizationSegments)
                continue
            }

            let gap = max(0, segment.start - previous.end)
            let segmentSpeaker = dominantSpeaker(for: segment, in: diarizationSegments)
            // A nil speaker on either side means diarization couldn't confidently
            // place that segment — don't let that uncertainty block a merge.
            let sameSpeaker = mergedSpeaker == nil || segmentSpeaker == nil || mergedSpeaker == segmentSpeaker
            if gap <= turnMergeGapSeconds && sameSpeaker {
                merged[merged.count - 1] = SpeechSegment(
                    start: previous.start,
                    end: max(previous.end, segment.end),
                    text: joinText(previous.text, segment.text)
                )
                if mergedSpeaker == nil { mergedSpeaker = segmentSpeaker }
            } else {
                merged.append(segment)
                mergedSpeaker = segmentSpeaker
            }
        }

        return merged
    }

    /// Best-overlap (falling back to nearest-within-2s) diarized speaker for a
    /// segment. Returns nil when diarization is unavailable, has fewer than
    /// two distinct speakers (nothing to disambiguate), or has no usable
    /// match — mirroring TranscriptFormatter's own speaker assignment so a
    /// turn that's kept separate here is attributed the same way downstream.
    private static func dominantSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment]?
    ) -> String? {
        guard let diarizationSegments, !diarizationSegments.isEmpty,
              Set(diarizationSegments.map(\.speakerId)).count > 1 else { return nil }

        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1))

        var bestOverlap: Float = 0
        var bestSpeakerId: String?
        for diarSeg in diarizationSegments {
            let overlapStart = max(segStart, diarSeg.startTimeSeconds)
            let overlapEnd = min(segEnd, diarSeg.endTimeSeconds)
            let overlap = max(0, overlapEnd - overlapStart)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerId = diarSeg.speakerId
            }
        }
        if let bestSpeakerId, bestOverlap > 0 { return bestSpeakerId }

        let segMidpoint = (segStart + segEnd) / 2
        guard let nearest = diarizationSegments.min(by: { lhs, rhs in
            temporalGap(between: segMidpoint, and: lhs) < temporalGap(between: segMidpoint, and: rhs)
        }) else { return nil }
        return temporalGap(between: segMidpoint, and: nearest) <= 2.0 ? nearest.speakerId : nil
    }

    private static func temporalGap(between point: Float, and diarizationSegment: TimedSpeakerSegment) -> Float {
        if point < diarizationSegment.startTimeSeconds {
            return diarizationSegment.startTimeSeconds - point
        }
        if point > diarizationSegment.endTimeSeconds {
            return point - diarizationSegment.endTimeSeconds
        }
        return 0
    }

    private static func dedupeSystemSegments(_ systemSegments: [SpeechSegment]) -> [SpeechSegment] {
        let orderedSegments = sortedSegments(systemSegments)

        return orderedSegments.enumerated().compactMap { index, segment in
            let normalizedSegmentText = normalizedText(segment.text)
            guard !normalizedSegmentText.isEmpty else { return nil }

            let shouldDrop = orderedSegments.enumerated().contains { otherIndex, otherSegment in
                guard otherIndex != index else { return false }
                let overlapCoverage = overlapCoverage(of: segment, across: [otherSegment])
                guard overlapCoverage >= 0.5 else { return false }

                let normalizedOtherText = normalizedText(otherSegment.text)
                guard !normalizedOtherText.isEmpty else { return false }

                let segmentVisibleLength = visibleLength(of: segment.text)
                guard segmentVisibleLength < 12 else { return false }

                if normalizedOtherText.contains(normalizedSegmentText) {
                    return true
                }

                let segmentTokens = tokenSet(from: normalizedSegmentText)
                let otherTokens = tokenSet(from: normalizedOtherText)
                return tokenContainmentRatio(source: segmentTokens, target: otherTokens) >= 0.67
            }

            return shouldDrop ? nil : segment
        }
    }

    private static func sortedSegments(_ segments: [SpeechSegment]) -> [SpeechSegment] {
        segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    private static func overlapCoverage(
        of segment: SpeechSegment,
        across otherSegments: [SpeechSegment]
    ) -> Double {
        let duration = max(segment.end - segment.start, 0.1)
        let overlap = unionOverlapDuration(of: segment, across: otherSegments)
        return overlap / duration
    }

    private static func unionOverlapDuration(
        of segment: SpeechSegment,
        across otherSegments: [SpeechSegment]
    ) -> TimeInterval {
        let clippedIntervals = otherSegments.compactMap { otherSegment -> (TimeInterval, TimeInterval)? in
            let overlapStart = max(segment.start, otherSegment.start)
            let overlapEnd = min(segment.end, otherSegment.end)
            guard overlapEnd > overlapStart else { return nil }
            return (overlapStart, overlapEnd)
        }.sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1 < rhs.1
            }
            return lhs.0 < rhs.0
        }

        guard var current = clippedIntervals.first else { return 0 }
        var total: TimeInterval = 0

        for interval in clippedIntervals.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1 - current.0
                current = interval
            }
        }

        total += current.1 - current.0
        return total
    }

    private static func normalizedText(_ text: String) -> String {
        let lowercase = text.lowercased()
        let replaced = lowercase.replacingOccurrences(
            of: #"[^\p{L}\p{M}\p{N}\s]"#,
            with: " ",
            options: .regularExpression
        )
        return replaced.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenSet(from text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }

    private static func tokenContainmentRatio(source: Set<String>, target: Set<String>) -> Double {
        guard !source.isEmpty else { return 0 }
        return Double(source.intersection(target).count) / Double(source.count)
    }

    private static func visibleLength(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : 1)
        }
    }

    private static func joinText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return lhs + rhs
        }

        if lhsLast.isWhitespace || rhsFirst.isWhitespace || rhsFirst.isPunctuation {
            return lhs + rhs
        }

        if lhsLast.isPunctuation {
            return lhs + " " + rhs
        }

        return lhs + " " + rhs
    }
}
