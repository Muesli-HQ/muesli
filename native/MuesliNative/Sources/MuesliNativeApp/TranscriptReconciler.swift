import FluidAudio
import Foundation
import MuesliCore

struct ReconciledTranscriptInputs {
    let micSegments: [SpeechSegment]
    let systemSegments: [SpeechSegment]
    let diarizationSegments: [TimedSpeakerSegment]?
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
        diarizationSegments: [TimedSpeakerSegment]?
    ) -> ReconciledTranscriptInputs {
        let normalizedMicTurns = mergeReadableSegments(sortedSegments(micTurns))
        let normalizedSystemTurns = sortedSegments(dedupeSystemSegments(systemSegments))
        let windows = buildWindows(
            micTurns: normalizedMicTurns,
            systemTurns: normalizedSystemTurns
        )

        var keptMicTurns: [SpeechSegment] = []
        var keptSystemTurns: [SpeechSegment] = []

        for window in windows {
            let reconciledWindow = reconcile(window)
            keptMicTurns.append(contentsOf: reconciledWindow.micTurns)
            keptSystemTurns.append(contentsOf: reconciledWindow.systemTurns)
        }

        return ReconciledTranscriptInputs(
            micSegments: sortedSegments(keptMicTurns),
            systemSegments: sortedSegments(keptSystemTurns),
            diarizationSegments: diarizationSegments
        )
    }

    private static func reconcile(_ window: OverlapWindow) -> OverlapWindow {
        let mergedMicTurns = mergeReadableSegments(window.micTurns)
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
            mergedMicTurns.filter { shouldKeepMicTurn($0, overlappingSystemTurns: keptSystemTurns) }
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

    private static func mergeReadableSegments(_ segments: [SpeechSegment]) -> [SpeechSegment] {
        guard !segments.isEmpty else { return [] }

        let orderedSegments = sortedSegments(segments)
        var merged: [SpeechSegment] = [orderedSegments[0]]

        for segment in orderedSegments.dropFirst() {
            guard let previous = merged.last else {
                merged.append(segment)
                continue
            }

            let gap = max(0, segment.start - previous.end)
            if gap <= turnMergeGapSeconds {
                merged[merged.count - 1] = SpeechSegment(
                    start: previous.start,
                    end: max(previous.end, segment.end),
                    text: joinText(previous.text, segment.text)
                )
            } else {
                merged.append(segment)
            }
        }

        return merged
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
