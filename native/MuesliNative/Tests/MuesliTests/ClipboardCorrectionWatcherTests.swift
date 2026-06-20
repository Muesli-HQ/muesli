import Testing
import Foundation
import AppKit
import MuesliCore
@testable import MuesliNativeApp

@Suite("Clipboard Correction Watcher")
struct ClipboardCorrectionWatcherTests {

    @Test("identical text yields no corrections")
    func identical() {
        let result = ClipboardCorrectionWatcher.corrections(from: "deploy to kubernetes", to: "deploy to kubernetes")
        #expect(result.isEmpty)
    }

    @Test("a single in-place word fix is captured")
    func singleFix() {
        let result = ClipboardCorrectionWatcher.corrections(from: "deploy to kubernetez now", to: "deploy to kubernetes now")
        #expect(result.count == 1)
        #expect(result.first?.word == "kubernetez")
        #expect(result.first?.replacement == "kubernetes")
    }

    @Test("unrelated text (too dissimilar) yields no corrections")
    func unrelated() {
        let result = ClipboardCorrectionWatcher.corrections(from: "deploy to kubernetes", to: "buy milk and eggs")
        #expect(result.isEmpty)
    }

    @Test("length changes (insert/delete) are ignored")
    func lengthChange() {
        let result = ClipboardCorrectionWatcher.corrections(from: "deploy kubernetes", to: "deploy to kubernetes")
        #expect(result.isEmpty)
    }

    @Test("a substitution of an unrelated word is not treated as a correction")
    func dissimilarSubstitution() {
        // Same length, mostly matching, but the changed word is nothing like the original.
        let result = ClipboardCorrectionWatcher.corrections(from: "send the report today", to: "send the banana today")
        #expect(result.isEmpty)
    }

    @Test("punctuation around the corrected word is tolerated")
    func punctuationTolerated() {
        let result = ClipboardCorrectionWatcher.corrections(from: "I love muesli.", to: "I love müsli.")
        #expect(result.first?.word == "muesli")
        #expect(result.first?.replacement == "müsli")
    }

    @Test("empty inputs yield no corrections")
    func emptyInputs() {
        #expect(ClipboardCorrectionWatcher.corrections(from: "", to: "").isEmpty)
        #expect(ClipboardCorrectionWatcher.corrections(from: "", to: "hello").isEmpty)
        #expect(ClipboardCorrectionWatcher.corrections(from: "hello", to: "").isEmpty)
    }

    @Test("a capitalization-only fix is captured with the cased replacement")
    func capitalizationFix() {
        let result = ClipboardCorrectionWatcher.corrections(from: "ship to github today", to: "ship to GitHub today")
        #expect(result.count == 1)
        #expect(result.first?.word == "github")   // match side lowercased
        #expect(result.first?.replacement == "GitHub")
    }

    @Test("multiple in-place fixes are all captured when within the change budget")
    func multipleFixes() {
        // 2 of 8 tokens changed -> within 30% budget; both are near-matches.
        let result = ClipboardCorrectionWatcher.corrections(
            from: "deploy kubernetez and run kubecti on the cluster",
            to:   "deploy kubernetes and run kubectl on the cluster"
        )
        let words = Set(result.map(\.word))
        #expect(words == ["kubernetez", "kubecti"])
    }

    @Test("too many changed tokens is treated as an unrelated copy")
    func tooManyChanges() {
        // 3 of 4 differ -> exceeds the change budget -> rejected wholesale.
        let result = ClipboardCorrectionWatcher.corrections(from: "alpha beta gamma delta", to: "alpha one two three")
        #expect(result.isEmpty)
    }

    @Test("a changed token that is purely punctuation is skipped")
    func punctuationOnlyChangeSkipped() {
        // "end." vs "end!" -> cores are identical after stripping, so not a diff;
        // "go" vs "--" -> the replacement has no letter, so it's skipped.
        let result = ClipboardCorrectionWatcher.corrections(from: "go now", to: "-- now")
        #expect(result.isEmpty)
    }

    @Test("whitespace differences alone are not corrections")
    func whitespaceOnly() {
        let result = ClipboardCorrectionWatcher.corrections(from: "hello   world", to: "hello world")
        #expect(result.isEmpty)
    }

    // MARK: - Event-driven instance flow

    /// Use a uniquely-named pasteboard so tests never touch the real clipboard.
    @MainActor
    private func makeIsolated() -> (ClipboardCorrectionWatcher, NSPasteboard) {
        let pb = NSPasteboard(name: NSPasteboard.Name("muesli.test.\(UUID().uuidString)"))
        pb.clearContents()
        return (ClipboardCorrectionWatcher(pasteboard: pb), pb)
    }

    @Test("check before any paste reports nothing")
    @MainActor
    func checkWithoutPaste() {
        let (watcher, _) = makeIsolated()
        var calls = 0
        watcher.checkForCorrections { _ in calls += 1 }
        #expect(calls == 0)
    }

    @Test("a corrected re-copy is captured at the next check")
    @MainActor
    func correctedRecopyCaptured() {
        let (watcher, pb) = makeIsolated()
        watcher.recordPaste("deploy to kubernetez now")
        // User fixes the word and re-copies it.
        pb.clearContents()
        pb.setString("deploy to kubernetes now", forType: .string)

        var captured: [SuggestedWordUpsert] = []
        watcher.checkForCorrections { captured = $0 }
        #expect(captured.count == 1)
        #expect(captured.first?.word == "kubernetez")
        #expect(captured.first?.replacement == "kubernetes")
    }

    @Test("an unchanged clipboard yields no corrections")
    @MainActor
    func unchangedClipboard() {
        let (watcher, pb) = makeIsolated()
        watcher.recordPaste("deploy to kubernetes now")
        pb.clearContents()
        pb.setString("deploy to kubernetes now", forType: .string)

        var calls = 0
        watcher.checkForCorrections { _ in calls += 1 }
        #expect(calls == 0)
    }

    @Test("each paste is checked at most once")
    @MainActor
    func pendingConsumedAfterCheck() {
        let (watcher, pb) = makeIsolated()
        watcher.recordPaste("deploy to kubernetez now")
        pb.clearContents()
        pb.setString("deploy to kubernetes now", forType: .string)

        var calls = 0
        watcher.checkForCorrections { _ in calls += 1 }
        watcher.checkForCorrections { _ in calls += 1 }   // nothing pending now
        #expect(calls == 1)
    }

    @Test("cancel clears the pending paste so no correction is reported")
    @MainActor
    func cancelClearsPending() {
        let (watcher, pb) = makeIsolated()
        watcher.recordPaste("deploy to kubernetez now")
        pb.clearContents()
        pb.setString("deploy to kubernetes now", forType: .string)

        watcher.cancel()
        var calls = 0
        watcher.checkForCorrections { _ in calls += 1 }
        #expect(calls == 0)
    }
}
