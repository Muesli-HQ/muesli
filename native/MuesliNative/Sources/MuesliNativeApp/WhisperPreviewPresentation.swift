import Foundation

/// Display proposals only. Agreement here never commits words, trims audio, or
/// acknowledges an editor write; the engine and target retain those decisions.
struct WhisperPreviewPresentation {
    private var previousHypothesis = ""
    private var previousWordEnds: Set<Int> = []
    private var visible = ""
    private var visibleWordEnds: Set<Int> = []
    private var heldSmallAddition = false

    mutating func present(committedText: String, tail: String,
                          words: [BufferedTranscriptionWord], final: Bool) -> String {
        let full = committedText + tail
        let committedCount = committedText.utf16.count
        let compatible = visible.utf16.starts(with: committedText.utf16)
        guard let ends = Self.wordEnds(in: tail, words: words) else {
            if final { visible = full; return tail }
            return compatible ? Self.suffix(visible, after: committedCount) : ""
        }
        let fullEnds = Set(ends.map { committedCount + $0 })
        let common = Self.commonPrefix(previousHypothesis, full)
        let agreed = fullEnds.filter { $0 <= common && previousWordEnds.contains($0) }.max() ?? committedCount
        defer {
            previousHypothesis = full
            previousWordEnds = fullEnds
        }
        if final {
            visible = full
            visibleWordEnds = fullEnds
            heldSmallAddition = false
            return tail
        }

        let stableEnd = max(0, agreed - committedCount)
        var desiredEnd = stableEnd
        var draftWords = 0
        for end in ends where end > stableEnd {
            guard draftWords < 2 else { break }
            let draft = Self.slice(tail, from: stableEnd, to: end)
            if draft.count > 24 {
                // A single long word may be shown partially, but never split a
                // combining sequence, surrogate pair, or joined emoji.
                if draftWords == 0 { desiredEnd = stableEnd + draft.prefix(24).utf16.count }
                break
            }
            desiredEnd = end
            draftWords += 1
        }
        let proposed = committedText + Self.slice(tail, from: 0, to: desiredEnd)
        let canKeepVisible = compatible && full.utf16.starts(with: visible.utf16)
        if canKeepVisible, visible.utf16.starts(with: proposed.utf16) {
            // A commitment transfer or grouping boundary is not a reason to
            // erase text that still exactly matches the current hypothesis.
            heldSmallAddition = false
            return Self.suffix(visible, after: committedCount)
        }

        let shared = Self.commonPrefix(visible, proposed)
        let changedWords = visibleWordEnds.filter { $0 > shared }.count
        let rewritten = Self.suffix(visible, after: shared).count
        let largeRevision = changedWords > 2 || rewritten > 24
        let confirmedReplacement = agreed >= min(visible.utf16.count, proposed.utf16.count)
        if compatible, largeRevision, !confirmedReplacement {
            heldSmallAddition = false
            return Self.suffix(visible, after: committedCount)
        }

        let extendsVisible = proposed.utf16.starts(with: visible.utf16)
        let addedWords = fullEnds.filter { $0 > visible.utf16.count && $0 <= proposed.utf16.count }.count
        if compatible, extendsVisible, !proposed.utf16.elementsEqual(visible.utf16), addedWords < 2,
           agreed < proposed.utf16.count,
           !heldSmallAddition {
            heldSmallAddition = true
            return Self.suffix(visible, after: committedCount)
        }
        heldSmallAddition = false
        visible = proposed
        visibleWordEnds = fullEnds.filter { $0 <= proposed.utf16.count }
        return Self.suffix(proposed, after: committedCount)
    }

    private static func wordEnds(in tail: String, words: [BufferedTranscriptionWord]) -> [Int]? {
        let joined = words.map(\.text).joined()
        let leading: Int
        if joined.utf16.elementsEqual(tail.utf16) { leading = 0 }
        else if (" " + joined).utf16.elementsEqual(tail.utf16) { leading = 1 }
        else { return nil }
        var valid: Set<Int> = [0]
        var offset = 0
        for character in tail { offset += String(character).utf16.count; valid.insert(offset) }
        offset = leading
        return words.compactMap { word in
            offset += word.text.utf16.count
            return valid.contains(offset) ? offset : nil
        }
    }

    /// Return an exact UTF-16 prefix ending at a grapheme boundary in both texts.
    private static func commonPrefix(_ lhs: String, _ rhs: String) -> Int {
        var offset = 0
        for (a, b) in zip(lhs, rhs) {
            guard String(a).utf16.elementsEqual(String(b).utf16) else { break }
            offset += String(a).utf16.count
        }
        return offset
    }

    private static func suffix(_ text: String, after offset: Int) -> String {
        slice(text, from: offset, to: text.utf16.count)
    }

    private static func slice(_ text: String, from start: Int, to end: Int) -> String {
        (text as NSString).substring(with: NSRange(location: start, length: end - start))
    }
}
