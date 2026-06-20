import AppKit
import Foundation
import MuesliCore

/// Opt-in learner of dictionary corrections from the user's own edits.
///
/// After Muesli pastes a dictation, the user may fix a misspelled word and
/// re-copy the corrected text. We diff that corrected text against what we pasted
/// and extract word-level corrections as high-confidence suggestions.
///
/// This is **default-off** (`AppConfig.enableClipboardCorrectionTracking`).
/// Detection is **event-driven, not polling**: AppKit exposes no clipboard-change
/// notification, so rather than sampling `NSPasteboard` on a timer (unreliable
/// under App Nap in this LSUIElement app, and it trips a macOS "used the
/// clipboard" notice on every read), we remember the last pasted text and inspect
/// the clipboard exactly **once** at the next natural event — the start of the
/// following dictation. If the user re-copied a corrected version in the
/// meantime, the single diff captures it; otherwise the heavy guards in
/// `corrections(from:to:)` reject whatever unrelated text is on the clipboard.
///
/// Trade-off vs. polling: a correction is only learned if the user re-copies it
/// before their next dictation. That covers the intended "fix it, copy it, move
/// on" flow without any background timer or clipboard surveillance.
@MainActor
final class ClipboardCorrectionWatcher {
    /// Corrected text must be this similar to the pasted text overall — a real
    /// edit, not a different copy entirely.
    nonisolated private static let minOverallSimilarity = 0.7

    private let pasteboard: NSPasteboard
    /// The text Muesli most recently pasted, awaiting a one-shot correction check
    /// at the next dictation start. Consumed (set to nil) once checked.
    private var pendingPastedText: String?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Remember the text we just pasted so the next dictation start can check
    /// whether the user re-copied a corrected version of it.
    func recordPaste(_ pastedText: String) {
        pendingPastedText = pastedText
    }

    /// Inspect the clipboard once for an edited version of the last pasted text
    /// and report any word-level corrections. Call at a natural event (e.g. the
    /// next dictation start) — never on a timer. The pending text is consumed
    /// whether or not a correction is found, so each paste is checked at most once.
    func checkForCorrections(onCorrections: ([SuggestedWordUpsert]) -> Void) {
        guard let pastedText = pendingPastedText else { return }
        pendingPastedText = nil
        guard let current = pasteboard.string(forType: .string) else { return }
        let corrections = Self.corrections(from: pastedText, to: current)
        if !corrections.isEmpty {
            onCorrections(corrections)
        }
    }

    func cancel() {
        pendingPastedText = nil
    }

    // MARK: - Pure diff (testable)

    /// Diff pasted text against the (presumably edited) clipboard text and return
    /// the words that changed in place as corrections. Returns empty if the two
    /// texts are identical, too dissimilar to be an edit, or differ in length
    /// (insertions/deletions are ignored — only same-position substitutions are
    /// treated as corrections).
    nonisolated static func corrections(from pasted: String, to edited: String) -> [SuggestedWordUpsert] {
        let pastedTokens = tokenize(pasted)
        let editedTokens = tokenize(edited)
        guard !pastedTokens.isEmpty,
              pastedTokens.count == editedTokens.count,
              pastedTokens != editedTokens else {
            return []
        }

        // Guard against unrelated clipboard copies: only a small minority of
        // tokens may differ (always allowing at least one change, so a short
        // sentence with a single fix still counts as an edit).
        let differing = zip(pastedTokens, editedTokens).filter { $0 != $1 }.count
        let maxDiffering = max(1, Int((1.0 - minOverallSimilarity) * Double(pastedTokens.count)))
        guard differing <= maxDiffering else { return [] }

        var corrections: [SuggestedWordUpsert] = []
        for (original, corrected) in zip(pastedTokens, editedTokens) where original != corrected {
            // Only treat single-word substitutions of similar words as
            // corrections (filters out unrelated rewrites).
            guard corrected.contains(where: { $0.isLetter }),
                  CustomWordMatcher.jaroWinklerSimilarity(original.lowercased(), corrected.lowercased()) > 0.6 else {
                continue
            }
            corrections.append(SuggestedWordUpsert(
                word: original.lowercased(),
                replacement: corrected,
                occurrenceCount: WordSuggestionAnalyzer.minOccurrences,
                phoneticVariants: [],
                backends: []
            ))
        }
        return corrections
    }

    nonisolated private static let boundaryPunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")

    nonisolated private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .compactMap { raw in
                let core = raw.trimmingCharacters(in: boundaryPunctuation)
                return core.isEmpty ? nil : core
            }
    }
}
