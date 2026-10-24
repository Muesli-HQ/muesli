import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Live dictation text target", .serialized)
@MainActor
struct LiveDictationTextTargetTests {
    private final class Editor {
        var text: String
        var selection: NSRange
        var focused = true
        var selectionSucceeds = true
        var replacementSucceeds = true
        var corruptReadback = false
        var afterSelect: (() -> Void)?
        var afterReplacement: (() -> Void)?
        var delaySelection = false
        var delayReplacement = false
        var pendingSelection: NSRange?
        var pendingReplacement: String?
        var replacements = 0
        var selections = 0

        init(_ text: String = "Before  after", selection: NSRange = NSRange(location: 7, length: 0)) {
            self.text = text
            self.selection = selection
        }

        func flushSelection() {
            if let pendingSelection { selection = pendingSelection }
            pendingSelection = nil
        }

        func flushReplacement() {
            if let pendingReplacement { applyReplacement(pendingReplacement) }
            pendingReplacement = nil
        }

        private func applyReplacement(_ replacement: String) {
            text = (text as NSString).replacingCharacters(in: selection, with: replacement)
            selection = NSRange(location: selection.location + (replacement as NSString).length, length: 0)
            if corruptReadback { text += "!" }
        }

        var access: LiveDictationTextTarget.Access {
            .init(snapshot: { [self] in .init(text: text, selection: selection) },
                  isFocused: { [self] in focused },
                  select: { [self] range in
                      selections += 1
                      guard selectionSucceeds else { return false }
                      if delaySelection { pendingSelection = range } else { selection = range }
                      afterSelect?()
                      return true
                  }, replaceSelection: { [self] replacement in
                      replacements += 1
                      // Simulate an IPC call whose error does not prove no mutation.
                      if delayReplacement {
                          pendingReplacement = replacement
                      } else {
                          applyReplacement(replacement)
                      }
                      afterReplacement?()
                      return replacementSucceeds
                  })
        }
    }

    @Test func revisesOnlyOwnedRangeAndFinishes() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "yellow"))
        #expect(await target.update(text: "hello world"))
        #expect(await target.finish(text: "Hello, world. "))
        #expect(editor.text == "Before Hello, world.  after")
        #expect(target.hasInsertedText)
        #expect(target.hasAttemptedWrite)
        #expect(await target.update(text: "late") == false)
        #expect(editor.replacements == 3)
    }

    @Test func replacesInitialSelectionAndHandlesUTF16() async throws {
        let editor = Editor("🦊 old fin", selection: NSRange(location: 3, length: 3))
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "👩🏽‍💻 नमस्ते"))
        #expect(editor.text == "🦊 👩🏽‍💻 नमस्ते fin")
        #expect(await target.update(text: "😀 café"))
        #expect(editor.text == "🦊 😀 café fin")
        #expect(editor.selection == NSRange(location: 3 + ("😀 café" as NSString).length, length: 0))
    }

    @Test func emptyInitialHypothesisPreservesSelection() async throws {
        let editor = Editor("selected", selection: NSRange(location: 0, length: 8))
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: ""))
        #expect(editor.text == "selected")
        #expect(!target.hasAttemptedWrite)
        #expect(editor.selections == 0)
    }

    @Test func rejectsInvalidAndSplitSurrogateRanges() {
        for range in [NSRange(location: 100, length: 0), NSRange(location: 0, length: 100), NSRange(location: 1, length: 0)] {
            let editor = Editor("😀", selection: range)
            #expect(LiveDictationTextTarget(access: editor.access) == nil)
        }
    }

    @Test func focusLossPermanentlySuspends() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "first"))
        editor.focused = false
        #expect(await target.update(text: "wrong app") == false)
        editor.focused = true
        #expect(await target.finish(text: "back again") == false)
        #expect(target.isSuspended)
        #expect(editor.text == "Before first after")
    }

    @Test func userEditOrCaretMoveStopsWrites() async throws {
        for changesText in [true, false] {
            let editor = Editor()
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(text: "first"))
            if changesText { editor.text += "user edit" } else { editor.selection.location = 0 }
            let before = editor.text
            #expect(await target.update(text: "overwrite") == false)
            #expect(target.isSuspended)
            #expect(editor.text == before)
            #expect(editor.replacements == 1)
        }
    }

    @Test func canonicallyEquivalentUserEditStillRevokesOwnership() async throws {
        let editor = Editor("é ", selection: NSRange(location: 2, length: 0))
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.text = "e\u{301} "
        #expect(await target.update(text: "hello") == false)
        #expect(target.isSuspended)
        #expect(editor.replacements == 0)
    }

    @Test func ownReentrantAndDelayedNotificationsDoNotSuspend() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.afterSelect = { target.textTargetDidChange() }
        editor.afterReplacement = { target.textTargetDidChange() }
        #expect(await target.update(text: "first"))
        target.textTargetDidChange()
        #expect(await target.update(text: "revision"))
        #expect(!target.isSuspended)
        #expect(editor.text == "Before revision after")
        // A later external change is observed even without another ASR update.
        editor.selection.location = 0
        target.textTargetDidChange()
        #expect(target.isSuspended)
    }

    @Test func cancellationDuringSelectionPreventsTextWrite() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.afterSelect = { target.cancel() }
        #expect(await target.update(text: "late") == false)
        #expect(editor.replacements == 0)
    }

    @Test func redundantFocusNotificationKeepsSameFieldOwned() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        target.focusTargetDidChange()
        editor.afterSelect = { target.focusTargetDidChange() }
        editor.afterReplacement = { target.focusTargetDidChange() }
        #expect(await target.update(text: "live text"))
        #expect(await target.finish(text: "Cleaned text."))
        #expect(editor.text == "Before Cleaned text. after")
        #expect(!target.isSuspended)
    }

    @Test func focusNotificationForDifferentFieldPermanentlyRevokesOwnership() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.focused = false
        target.focusTargetDidChange()
        editor.focused = true
        #expect(await target.update(text: "must not insert") == false)
        #expect(target.isSuspended)
        #expect(editor.replacements == 0)
    }

    @Test func focusLossBetweenSelectionAndTextPreventsReplacement() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.afterSelect = { editor.focused = false }
        #expect(await target.update(text: "unsafe") == false)
        #expect(target.hasAttemptedWrite)
        #expect(target.isSuspended)
        #expect(editor.replacements == 0)
    }

    @Test func failedOrMismatchedWritesAreNeverRetried() async throws {
        for readbackFailure in [true, false] {
            let editor = Editor()
            editor.corruptReadback = readbackFailure
            editor.replacementSucceeds = readbackFailure
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(text: "possibly inserted") == false)
            #expect(target.hasAttemptedWrite)
            #expect(target.isSuspended)
            #expect(await target.finish(text: "duplicate") == false)
            #expect(editor.replacements == 1)
        }
    }

    @Test func failedSelectionStopsBeforeReplacement() async throws {
        let editor = Editor()
        editor.selectionSucceeds = false
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "hello") == false)
        #expect(target.hasAttemptedWrite)
        #expect(target.isSuspended)
        #expect(editor.replacements == 0)
    }

    @Test func cancellationLeavesInsertedTextAndRejectsLateOutput() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "keep"))
        target.cancel()
        #expect(await target.update(text: "late") == false)
        #expect(await target.finish(text: "later") == false)
        #expect(editor.text == "Before keep after")
    }

    @Test func newSessionRetiresOldOwnership() async throws {
        let first = Editor()
        let old = try #require(LiveDictationTextTarget(access: first.access))
        let second = Editor()
        let new = try #require(LiveDictationTextTarget(access: second.access))
        #expect(await old.update(text: "old") == false)
        #expect(await new.update(text: "new"))
        #expect(first.replacements == 0)
    }

    private final class PollClock {
        var ticks = 0
        var onWait: () -> Void = {}
        var timing: LiveDictationTextTarget.ReadbackTiming {
            .init(timeout: 0.05, now: { [self] in Double(ticks) * 0.01 }, wait: { [self] in
                ticks += 1
                onWait()
                await Task.yield()
            })
        }
    }

    @Test func delayedSelectionReadbackWaitsWithoutRepeatingWrite() async throws {
        let editor = Editor()
        let clock = PollClock()
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
        #expect(await target.update(text: "first"))
        editor.delaySelection = true
        clock.onWait = { if clock.ticks == 2 { editor.flushSelection() } }
        #expect(await target.update(text: "revision"))
        #expect(editor.text == "Before revision after")
        #expect(editor.selections == 2)
        #expect(editor.replacements == 2)
        #expect(clock.ticks == 2)
    }

    @Test func delayedTextReadbackWaitsWithoutRepeatingWrite() async throws {
        let editor = Editor()
        let clock = PollClock()
        editor.delayReplacement = true
        clock.onWait = { if clock.ticks == 2 { editor.flushReplacement() } }
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
        #expect(await target.update(text: "hello"))
        #expect(editor.text == "Before hello after")
        #expect(editor.replacements == 1)
        #expect(clock.ticks == 2)
    }

    @Test func readbackTimeoutPermanentlySuspendsWithoutRetry() async throws {
        let editor = Editor()
        let clock = PollClock()
        editor.delayReplacement = true
        var reasons: [String] = []
        let target = try #require(LiveDictationTextTarget(access: editor.access,
            onDiagnostic: { reasons.append($0) }, readbackTiming: clock.timing))
        #expect(await target.update(text: "late") == false)
        #expect(target.isSuspended)
        #expect(reasons == ["text_readback_timeout"])
        editor.flushReplacement()
        #expect(await target.finish(text: "do not retry") == false)
        #expect(editor.replacements == 1)
    }

    @Test func unexpectedEditDuringReadbackRevokesOwnership() async throws {
        let editor = Editor()
        let clock = PollClock()
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
        #expect(await target.update(text: "first"))
        editor.delaySelection = true
        clock.onWait = { editor.text += " user edit" }
        #expect(await target.update(text: "revision") == false)
        #expect(target.isSuspended)
        #expect(editor.replacements == 1)
    }

    @Test func cancelDuringReadbackRejectsLateAcknowledgement() async throws {
        let editor = Editor()
        let clock = PollClock()
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
        #expect(await target.update(text: "first"))
        editor.delaySelection = true
        clock.onWait = { target.cancel(); editor.flushSelection() }
        #expect(await target.update(text: "revision") == false)
        #expect(editor.replacements == 1)
        #expect(await target.finish(text: "late final") == false)
    }

    @Test func knownAppDepartureRevokesEvenAfterFocusReturned() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        // The foreign-activation event arrived after the user returned here.
        #expect(editor.focused)
        target.focusTargetDidDepart()
        #expect(await target.update(text: "must not insert") == false)
        #expect(target.isSuspended)
        #expect(editor.replacements == 0)
    }

    @Test func finalWaitsForPreviewAndRejectsLaterPreview() async throws {
        let editor = Editor()
        editor.delayReplacement = true
        var waiting: CheckedContinuation<Void, Never>?
        let timing = LiveDictationTextTarget.ReadbackTiming(timeout: 1, now: { 0 }, wait: {
            await withCheckedContinuation { waiting = $0 }
        })
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
        let preview = Task { @MainActor in await target.update(text: "preview") }
        while waiting == nil { await Task.yield() }
        var finishStarted = false
        let final = Task { @MainActor in
            finishStarted = true
            return await target.finish(text: "Final.")
        }
        while !finishStarted { await Task.yield() }
        #expect(await target.update(text: "late preview") == false)
        #expect(editor.replacements == 1)
        editor.delayReplacement = false
        editor.flushReplacement()
        waiting?.resume()
        waiting = nil
        #expect(await preview.value)
        #expect(await final.value)
        #expect(editor.text == "Before Final. after")
        #expect(editor.replacements == 2)
    }


    @Test func focusLossDuringReadbackRejectsLateText() async throws {
        let editor = Editor()
        let clock = PollClock()
        editor.delayReplacement = true
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
        clock.onWait = { editor.focused = false; editor.flushReplacement() }
        #expect(await target.update(text: "possibly delivered") == false)
        editor.focused = true
        #expect(target.isSuspended)
        #expect(await target.finish(text: "do not overwrite") == false)
        #expect(editor.replacements == 1)
    }

    @Test func cancellationDrainsQueuedFinalAndActivePreview() async throws {
        let editor = Editor()
        editor.delayReplacement = true
        var waiting: CheckedContinuation<Void, Never>?
        let timing = LiveDictationTextTarget.ReadbackTiming(timeout: 1, now: { 0 }, wait: {
            await withCheckedContinuation { waiting = $0 }
        })
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
        let preview = Task { @MainActor in await target.update(text: "preview") }
        while waiting == nil { await Task.yield() }
        var finishStarted = false
        let final = Task { @MainActor in
            finishStarted = true
            return await target.finish(text: "Final.")
        }
        while !finishStarted { await Task.yield() }
        target.cancel()
        #expect(await final.value == false)
        editor.flushReplacement()
        waiting?.resume()
        waiting = nil
        #expect(await preview.value == false)
        #expect(editor.text == "Before preview after")
        #expect(editor.replacements == 1)
    }

}
