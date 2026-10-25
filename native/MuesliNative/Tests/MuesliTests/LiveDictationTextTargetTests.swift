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
        var focusUnavailable = false
        var snapshotUnavailable = false
        var afterPasteDispatch: (() -> Void)?
        var selectionSucceeds = true
        var replacementSucceeds = true
        var corruptReadback = false
        var afterSelect: (() -> Void)?
        var afterReplacement: (() -> Void)?
        var delaySelection = false
        var delayReplacement = false
        var pendingSelection: NSRange?
        var pendingReplacement: String?
        var replacementTextFirst = false
        var replacementCaretFirst = false
        var pendingText: String?
        var pendingCaret: NSRange?
        var replacements = 0
        var selections = 0
        var selectedRanges: [NSRange] = []
        var transport: LiveDictationTextTarget.Transport = .axSelectedText
        var keyboardSteps: [String] = []
        var keyboardNoOp = false
        var keyboardFailureAt: Int?
        var afterKeyboard: (() -> Void)?
        var beforeKeyboardValidation: (() -> Void)?
        var allowsEmptyLineSentinelRemoval = false
        var removesInitialNewline = false
        var keyboardBurstSize = 1
        var useAcknowledgedWordGroups = false
        var delayKeyboardSeparators = false
        var finalPasteEnabled = false
        var finalPastes: [String] = []
        var beforeFinalPaste: (() -> Void)?
        var finalPasteSucceeds = true
        var delayPaste = false
        var afterFinalAcknowledgement: (() -> Void)?

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
            var nextText = (text as NSString).replacingCharacters(in: selection, with: replacement)
            if removesInitialNewline, text.utf16.elementsEqual("\n".utf16),
               selection == NSRange(location: 0, length: 0) {
                nextText = replacement
            }
            let nextCaret = NSRange(location: selection.location + (replacement as NSString).length, length: 0)
            if replacementCaretFirst { pendingText = nextText } else { text = nextText }
            if replacementTextFirst { pendingCaret = nextCaret } else { selection = nextCaret }
            if corruptReadback { text += "!" }
        }

        func flushSplitReplacement() {
            if let pendingText { text = pendingText }
            if let pendingCaret { selection = pendingCaret }
            pendingText = nil
            pendingCaret = nil
        }

        var access: LiveDictationTextTarget.Access {
            let paste: LiveDictationTextTarget.Access.Paste? = finalPasteEnabled ? { [self] text, validate, acknowledge, _ in
                beforeFinalPaste?()
                guard await validate(), finalPasteSucceeds else { return false }
                finalPastes.append(text)
                if delayPaste { pendingReplacement = text } else { applyReplacement(text) }
                afterPasteDispatch?()
                let acknowledged = await acknowledge()
                afterFinalAcknowledgement?()
                return acknowledged
            } : nil
            return .init(snapshot: { [self] in snapshotUnavailable ? nil : .init(text: text, selection: selection) },
                  isFocused: { [self] in focused },
                  select: { [self] range in
                      selections += 1
                      selectedRanges.append(range)
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
                  }, transport: transport, keyboardPlan: { [self] text in
                      guard LiveDictationKeyboardInput.isSupported(text) else { return nil }
                      let values: [String]
                      if useAcknowledgedWordGroups {
                          guard let plan = LiveDictationKeyboardInput.makePlan(text: text, translate: { _, _ in nil }) else { return nil }
                          values = LiveDictationKeyboardInput.acknowledgmentGroups(plan).map { $0.map(\.text).joined() }
                      } else {
                          let characters = text.map(String.init)
                          values = stride(from: 0, to: characters.count, by: keyboardBurstSize).map { start in
                              characters[start..<min(start + keyboardBurstSize, characters.count)].joined()
                          }
                      }
                      return values.map { value in
                          .init(text: value, send: { [self] validate, onFailure in
                              beforeKeyboardValidation?()
                              guard validate() else {
                                  onFailure(.targetValidationFailed)
                                  return false
                              }
                              keyboardSteps.append(value)
                              if keyboardFailureAt == keyboardSteps.count {
                                  onFailure(.eventCreation)
                                  return false
                              }
                              if !keyboardNoOp {
                                  if delayKeyboardSeparators, value.contains(where: { $0.isWhitespace || $0.isPunctuation }) {
                                      pendingReplacement = value
                                  } else {
                                      applyReplacement(value)
                                  }
                              }
                              afterKeyboard?()
                              return true
                          })
                      }
                  }, allowsEmptyLineSentinelRemoval: allowsEmptyLineSentinelRemoval, paste: paste,
                    focusStatus: { [self] in
                        if !focused { return .departed("focus_changed") }
                        return focusUnavailable ? .unavailable("test_ax_unavailable") : .focused
                    })
        }
    }

    @Test(arguments: [false, true])
    func temporaryAccessibilityPausesWithoutWritingThenVerifiesOriginalSnapshot(snapshotFailure: Bool) async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let clock = PollClock()
        var diagnostics: [String] = []
        let target = try #require(LiveDictationTextTarget(access: editor.access,
            onDiagnostic: { diagnostics.append($0) }, readbackTiming: clock.timing))
        editor.focusUnavailable = !snapshotFailure
        editor.snapshotUnavailable = snapshotFailure
        target.focusTargetDidChange()
        #expect(target.isPaused)
        #expect(!target.isSuspended)
        clock.onWait = {
            #expect(editor.selections == 0)
            #expect(editor.finalPastes.isEmpty)
            editor.focusUnavailable = false
            editor.snapshotUnavailable = false
        }
        #expect(await target.update(committedText: "hello", tail: " world"))
        #expect(editor.finalPastes == ["hello world"])
        #expect(!target.isPaused)
        #expect(diagnostics.contains("accessibility_resumed"))
        #expect(await target.finish(text: "Hello world."))
        #expect(editor.text == "Before Hello world. after")
    }

    @Test func unavailableBeforeWriteDefersAndNextPreviewContinuesWithoutRecapture() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let clock = PollClock()
        var timing = clock.timing
        timing.availabilityTimeout = 0.03
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
        editor.focusUnavailable = true
        #expect(await target.update(committedText: "hello", tail: " old"))
        #expect(target.isPaused)
        #expect(!target.isSuspended)
        #expect(editor.selections == 0)
        #expect(editor.finalPastes.isEmpty)
        editor.focusUnavailable = false
        #expect(await target.update(committedText: "hello", tail: " latest"))
        #expect(editor.finalPastes == ["hello latest"])
        #expect(!target.isPaused)
    }

    @Test(arguments: [0, 1, 2, 3])
    func accessibilityRecoveryNeverReanchorsAfterEditCaretFocusOrCancellation(change: Int) async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let clock = PollClock()
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
        editor.focusUnavailable = true
        clock.onWait = {
            editor.focusUnavailable = false
            if change == 0 { editor.text += "user edit" }
            if change == 1 { editor.selection = NSRange(location: 2, length: 0) }
            if change == 2 { target.focusTargetDidDepart() } // Known departure remains fatal even after return.
            if change == 3 { target.cancel() }
        }
        #expect(await target.update(text: "must not insert") == false)
        #expect(editor.selections == 0)
        #expect(editor.finalPastes.isEmpty)
        #expect(await target.finish(text: "must not clean up") == false)
    }

    @Test(arguments: [false, true])
    func accessibilityLossBeforePasteOrDuringAckWaitsWithoutResending(afterDispatch: Bool) async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let clock = PollClock()
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
        if afterDispatch {
            editor.afterPasteDispatch = { editor.focusUnavailable = true; editor.snapshotUnavailable = true }
        } else {
            editor.beforeFinalPaste = { editor.focusUnavailable = true }
        }
        clock.onWait = {
            #expect(editor.finalPastes.count == (afterDispatch ? 1 : 0))
            editor.focusUnavailable = false
            editor.snapshotUnavailable = false
        }
        #expect(await target.update(text: "one exact paste"))
        #expect(editor.finalPastes == ["one exact paste"])
        #expect(!target.isSuspended)
        #expect(!target.isPaused)
    }

    @Test func persistentUnknownAfterDispatchStopsWithoutRetryOrFinalFallback() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let clock = PollClock()
        var timing = clock.timing
        timing.availabilityTimeout = 0.03
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
        editor.afterPasteDispatch = { editor.snapshotUnavailable = true }
        #expect(await target.update(text: "uncertain delivery") == false)
        #expect(target.isSuspended)
        #expect(editor.finalPastes.count == 1)
        editor.snapshotUnavailable = false
        #expect(await target.finish(text: "late cleanup") == false)
        #expect(editor.finalPastes.count == 1)
    }

    @Test func accessibilityBudgetIsSharedAcrossChunks() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let clock = PollClock()
        var timing = clock.timing
        timing.availabilityTimeout = 0.025
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
        editor.afterPasteDispatch = { editor.focusUnavailable = true }
        clock.onWait = { editor.focusUnavailable = false }
        #expect(await target.update(text: String(repeating: "word ", count: 200)) == false)
        #expect(clock.ticks <= 3)
        #expect(editor.finalPastes.count <= 4)
        #expect(target.isSuspended)
    }

    @Test func unavailableFinalWithoutPasteNeverClaimsDelivery() async throws {
        let editor = Editor()
        let clock = PollClock()
        var timing = clock.timing
        timing.availabilityTimeout = 0.02
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
        editor.focusUnavailable = true
        #expect(await target.finish(text: "not delivered") == false)
        #expect(editor.selections == 0)
        #expect(editor.replacements == 0)
    }

    @Test func finalCleanupWaitsForAccessibilityAndStillChecksExactSnapshot() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let clock = PollClock()
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
        #expect(await target.update(text: "draft"))
        editor.focusUnavailable = true
        clock.onWait = {
            #expect(editor.finalPastes == ["draft"])
            editor.focusUnavailable = false
        }
        #expect(await target.finish(text: "Draft."))
        #expect(editor.finalPastes == ["draft", "Draft."])
    }

    @Test func codexLivePastePreservesSpacesAndOnlyReplacesChangedSuffix() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(committedText: "This works", tail: " but this"))
        #expect(await target.update(committedText: "This works", tail: " but this also works"))
        #expect(editor.finalPastes == ["This works but this", " also works"])
        #expect(editor.keyboardSteps.isEmpty)
        #expect(editor.text == "Before This works but this also works after")
        #expect(await target.finish(text: "This works, but this also works."))
        #expect(editor.finalPastes.count == 3)
        #expect(editor.text == "Before This works, but this also works. after")
    }

    @Test func livePasteChunksPreserveUnicodeAndSurroundingDocument() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        let text = String(repeating: "வணக்கம் 👩🏽‍💻 e\u{301}  ", count: 30) + "done"
        #expect(await target.update(text: text))
        #expect(editor.finalPastes.count > 2)
        #expect(editor.finalPastes.allSatisfy { !$0.isEmpty && $0.utf16.count <= 128 })
        #expect(editor.finalPastes.joined().utf16.elementsEqual(text.utf16))
        #expect(editor.text.utf16.elementsEqual(("Before " + text + " after").utf16))
        #expect(editor.selection == NSRange(location: 7 + text.utf16.count, length: 0))
        #expect(editor.keyboardSteps.isEmpty)
    }

    @Test func livePastePreservesEmptyComposerSentinelContract() async throws {
        let editor = Editor("\n", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        editor.allowsEmptyLineSentinelRemoval = true
        editor.removesInitialNewline = true
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "This time"))
        #expect(await target.update(text: "This time it works"))
        #expect(editor.text == "This time it works")
        #expect(editor.finalPastes == ["This time", " it works"])
        #expect(editor.keyboardSteps.isEmpty)
    }

    @Test func livePasteStillDefersLargeDraftRewritesAndProtectsFrozenWords() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        let draft = String(repeating: "a", count: 90)
        #expect(await target.update(committedText: "hello", tail: " " + draft))
        let writes = editor.finalPastes.count
        #expect(await target.update(committedText: "hello", tail: " replacement"))
        #expect(editor.finalPastes.count == writes)
        #expect(editor.text == "Before hello " + draft + " after")
        #expect(await target.update(committedText: "different", tail: " words") == false)
        #expect(editor.finalPastes.count == writes)
        #expect(await target.finish(text: "must not overwrite") == false)
    }

    @Test func oversizedLivePasteGraphemeRejectsBeforeSelectionOrClipboardWrite() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "prefix " + "a" + String(repeating: "\u{301}", count: 128)) == false)
        #expect(editor.selections == 0)
        #expect(editor.finalPastes.isEmpty)
        #expect(editor.keyboardSteps.isEmpty)
    }

    @Test func livePasteFailedLaterChunkNeverRetriesOrFallsBack() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        editor.beforeFinalPaste = {
            if editor.finalPastes.count == 1 { editor.finalPasteSucceeds = false }
        }
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: String(repeating: "word ", count: 60)) == false)
        #expect(editor.finalPastes.count == 1)
        #expect(editor.text == "Before " + editor.finalPastes[0] + " after")
        #expect(editor.keyboardSteps.isEmpty)
        #expect(await target.finish(text: "late cleanup") == false)
        #expect(editor.finalPastes.count == 1)
    }

    @Test func livePasteRejectsChangedReadbackWithoutAnotherChunkOrFinalFallback() async throws {
        for change in 0..<5 {
            let editor = Editor()
            editor.transport = .targetedPaste
            editor.finalPasteEnabled = true
            editor.delayPaste = true
            let clock = PollClock()
            let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
            clock.onWait = {
                if change == 4 { return } // A missing ACK must time out, not repeat the paste.
                editor.flushReplacement()
                if change == 0 { editor.text += "user edit" }
                if change == 1 { editor.selection = NSRange(location: 1, length: 0) }
                if change == 2 { editor.focused = false }
                if change == 3 { target.cancel() }
            }
            #expect(await target.update(text: String(repeating: "word ", count: 60)) == false)
            #expect(editor.finalPastes.count == 1)
            #expect(editor.keyboardSteps.isEmpty)
            #expect(await target.finish(text: "late cleanup") == false)
        }
    }

    @Test func livePasteFinalWaitsForPendingChunkAndPerformsCleanupOnce() async throws {
        let editor = Editor()
        editor.transport = .targetedPaste
        editor.finalPasteEnabled = true
        editor.delayPaste = true
        var waiting: CheckedContinuation<Void, Never>?
        let timing = LiveDictationTextTarget.ReadbackTiming(timeout: 1, now: { 0 }, wait: {
            await withCheckedContinuation { waiting = $0 }
        })
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
        let text = String(repeating: "word ", count: 60) + "done"
        let preview = Task { @MainActor in await target.update(text: text) }
        while waiting == nil { await Task.yield() }
        var finalStarted = false
        let final = Task { @MainActor in
            finalStarted = true
            return await target.finish(text: text + ".")
        }
        while !finalStarted { await Task.yield() }
        #expect(editor.finalPastes.count == 1)
        #expect(await target.update(text: "late preview") == false)
        editor.delayPaste = false
        editor.flushReplacement()
        waiting?.resume()
        waiting = nil
        #expect(await preview.value)
        #expect(await final.value)
        #expect(editor.finalPastes.dropLast().joined() == text)
        #expect(editor.finalPastes.last == ".")
        #expect(editor.text == "Before " + text + ". after")
        #expect(editor.keyboardSteps.isEmpty)
    }

    @Test(arguments: [" ", ",", "\u{00A0}"])
    func wordGroupsWaitForSeparatorTextAndCaretBeforeContinuing(separator: String) async throws {
        let editor = Editor("", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.useAcknowledgedWordGroups = true
        editor.delayKeyboardSeparators = true
        let clock = PollClock()
        var waitingForCaret = false
        var expectedGroupCount = 0
        clock.onWait = {
            if waitingForCaret {
                #expect(editor.keyboardSteps.count == expectedGroupCount, "No following word before the separator caret ACK")
                editor.flushSplitReplacement()
                waitingForCaret = false
            } else {
                #expect(editor.pendingReplacement == separator)
                expectedGroupCount = editor.keyboardSteps.count
                editor.replacementTextFirst = true
                editor.flushReplacement()
                editor.replacementTextFirst = false
                waitingForCaret = true
            }
        }
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
        let text = "Can" + separator + "you" + separator + "check"
        #expect(await target.update(text: text))
        #expect(editor.keyboardSteps == ["C", "an", separator, "you", separator, "check"])
        #expect(editor.text == text)
        #expect(editor.selection == NSRange(location: 13, length: 0))
        #expect(clock.ticks == 4)
        #expect(!target.isSuspended)
    }

    @Test func wordGroupWaitStillRejectsEditsCaretMovementFocusLossAndCancellation() async throws {
        for change in 0..<4 {
            let editor = Editor("", selection: NSRange(location: 0, length: 0))
            editor.transport = .targetedKeyboard
            editor.useAcknowledgedWordGroups = true
            editor.delayKeyboardSeparators = true
            editor.finalPasteEnabled = true
            let clock = PollClock()
            let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
            clock.onWait = {
                editor.flushReplacement()
                if change == 0 { editor.text = "Cat " } // Same length still cannot pass exact readback.
                if change == 1 { editor.selection = NSRange(location: 1, length: 0) }
                if change == 2 { editor.focused = false }
                if change == 3 { target.cancel() }
            }
            #expect(await target.update(text: "Can you check") == false)
            #expect(editor.keyboardSteps == ["C", "an", " "])
            #expect(await target.finish(text: "Can you check?") == false)
            #expect(editor.finalPastes.isEmpty)
        }
    }

    @Test func punctuationTransformationCannotAuthorizeTheFollowingWord() async throws {
        let editor = Editor("", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.useAcknowledgedWordGroups = true
        editor.finalPasteEnabled = true
        editor.afterKeyboard = {
            if editor.keyboardSteps.last == "," { editor.text = "Can." }
        }
        var diagnostics: [String] = []
        let target = try #require(LiveDictationTextTarget(access: editor.access,
            onDiagnostic: { diagnostics.append($0) }))
        #expect(await target.update(text: "Can,you check") == false)
        #expect(diagnostics.last == "keyboard_text_readback_changed")
        #expect(editor.keyboardSteps == ["C", "an", ","])
        #expect(await target.finish(text: "Can you check?") == false)
        #expect(editor.finalPastes.isEmpty)
    }

    @Test func unacknowledgedSeparatorTimesOutWithoutRetryOrFollowingWord() async throws {
        let editor = Editor("", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.useAcknowledgedWordGroups = true
        editor.delayKeyboardSeparators = true
        editor.finalPasteEnabled = true
        let clock = PollClock()
        var diagnostics: [String] = []
        let target = try #require(LiveDictationTextTarget(access: editor.access,
            onDiagnostic: { diagnostics.append($0) }, readbackTiming: clock.timing))
        #expect(await target.update(text: "Can you check") == false)
        #expect(diagnostics.last == "keyboard_text_readback_timeout")
        #expect(editor.keyboardSteps == ["C", "an", " "])
        editor.flushReplacement() // A late ACK must not revive the suspended target.
        #expect(await target.update(text: "Can you check") == false)
        #expect(await target.finish(text: "Can you check?") == false)
        #expect(editor.finalPastes.isEmpty)
    }

    @Test func finalCleanupWaitsForWordGroupAcknowledgmentAndPastesOnlyOnce() async throws {
        let editor = Editor("", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.useAcknowledgedWordGroups = true
        editor.delayKeyboardSeparators = true
        editor.finalPasteEnabled = true
        var waiting: CheckedContinuation<Void, Never>?
        let timing = LiveDictationTextTarget.ReadbackTiming(timeout: 1, now: { 0 }, wait: {
            await withCheckedContinuation { waiting = $0 }
        })
        let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
        let preview = Task { @MainActor in await target.update(committedText: "Can", tail: " you check") }
        while waiting == nil { await Task.yield() }
        var finalStarted = false
        let final = Task { @MainActor in
            finalStarted = true
            return await target.finish(text: "Can you check?")
        }
        while !finalStarted { await Task.yield() }
        #expect(editor.keyboardSteps == ["C", "an", " "])
        #expect(editor.finalPastes.isEmpty)
        #expect(await target.update(text: "late preview") == false)
        editor.delayKeyboardSeparators = false
        editor.flushReplacement()
        waiting?.resume()
        waiting = nil
        #expect(await preview.value)
        #expect(await final.value)
        #expect(editor.keyboardSteps == ["C", "an", " ", "you", " ", "check"])
        #expect(editor.finalPastes == ["?"])
        #expect(editor.text == "Can you check?")
    }

    @Test func finalCleanupPastesChangedMiddleOnceAndPreservesContext() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        editor.useAcknowledgedWordGroups = true
        editor.finalPasteEnabled = true
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(committedText: "hello", tail: " old world"))
        let oldSteps = editor.keyboardSteps
        #expect(await target.finish(text: "Hello new world"))
        #expect(editor.finalPastes == ["Hello new"])
        #expect(editor.keyboardSteps == oldSteps)
        #expect(editor.text == "Before Hello new world after")
        #expect(editor.selection == NSRange(location: 7 + "Hello new world".utf16.count, length: 0))
        #expect(editor.replacements == 0)
    }

    @Test func finalPasteShorteningAndUnicodePreserveExactBoundaries() async throws {
        for (old, final) in [("hello extra", "hello"), ("extra hello", "hello"), ("👩🏽‍💻 old e\u{301}", "👩🏽‍💻 new e\u{301}")] {
            let editor = Editor()
            editor.transport = .targetedKeyboard
            editor.finalPasteEnabled = true
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(text: old))
            #expect(await target.finish(text: final))
            #expect(editor.finalPastes.count == 1)
            #expect(editor.finalPastes[0].isEmpty == false)
            #expect(editor.text.utf16.elementsEqual(("Before " + final + " after").utf16))
        }
    }

    @Test func finalPasteRejectsLateEditsAndNeverFallsBackToTyping() async throws {
        for change in 0..<3 {
            let editor = Editor()
            editor.transport = .targetedKeyboard
            editor.finalPasteEnabled = true
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(text: "draft"))
            let oldSteps = editor.keyboardSteps
            editor.beforeFinalPaste = {
                if change == 0 { editor.text += "user edit" }
                if change == 1 { editor.focused = false }
                if change == 2 { editor.finalPasteSucceeds = false }
            }
            #expect(await target.finish(text: "Clean final.") == false)
            #expect(editor.finalPastes.isEmpty)
            #expect(editor.keyboardSteps == oldSteps)
            #expect(target.isSuspended)
        }
    }

    @Test func identicalFinalAndEmptyFinalNeverTouchClipboard() async throws {
        for final in ["draft", ""] {
            let editor = Editor()
            editor.transport = .targetedKeyboard
            editor.finalPasteEnabled = true
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(text: "draft"))
            #expect(await target.finish(text: final))
            #expect(editor.finalPastes.isEmpty)
            #expect(editor.text == "Before draft after")
        }
    }

    @Test func finalPasteCanBeFirstInsertionIntoEmptyCodexComposer() async throws {
        let editor = Editor("\n", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.finalPasteEnabled = true
        editor.allowsEmptyLineSentinelRemoval = true
        editor.removesInitialNewline = true
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.finish(text: "Complete text."))
        #expect(editor.text == "Complete text.")
        #expect(editor.finalPastes == ["Complete text."])
        #expect(editor.keyboardSteps.isEmpty)
    }

    @Test func unacknowledgedFinalPasteNeverRetriesOrTypesFallback() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        editor.finalPasteEnabled = true
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "draft"))
        let steps = editor.keyboardSteps
        editor.corruptReadback = true
        #expect(await target.finish(text: "Clean final.") == false)
        #expect(editor.finalPastes.count == 1)
        #expect(editor.keyboardSteps == steps)
        #expect(await target.finish(text: "Retry") == false)
        #expect(editor.finalPastes.count == 1)
    }

    @Test func burstReadbackWaitsForWholeBatchAndRejectsUnrelatedText() async throws {
        for unrelated in [false, true] {
            let editor = Editor("", selection: NSRange(location: 0, length: 0))
            editor.transport = .targetedKeyboard
            editor.keyboardBurstSize = 8
            var ticks = 0
            editor.afterKeyboard = {
                if editor.keyboardSteps.count == 1 {
                    editor.text = unrelated ? "user" : "abc"
                    editor.selection = NSRange(location: unrelated ? 4 : 3, length: 0)
                }
            }
            let timing = LiveDictationTextTarget.ReadbackTiming(timeout: 0.5, now: { Double(ticks) * 0.1 }, wait: {
                ticks += 1
                #expect(editor.keyboardSteps == ["abcdefgh"])
                editor.text = "abcdefgh"
                editor.selection = NSRange(location: 8, length: 0)
            })
            let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
            #expect(await target.update(text: "abcdefghijklmnop") == !unrelated)
            #expect(editor.keyboardSteps.count == (unrelated ? 1 : 2))
            #expect(ticks == (unrelated ? 0 : 1))
            if !unrelated { #expect(editor.text == "abcdefghijklmnop") }
        }
    }

    @Test func cancellationDuringBurstAcknowledgementNeverSendsNextBurst() async throws {
        let editor = Editor("", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.keyboardBurstSize = 8
        editor.afterKeyboard = {
            editor.text = "abc"
            editor.selection = NSRange(location: 3, length: 0)
        }
        var target: LiveDictationTextTarget?
        let timing = LiveDictationTextTarget.ReadbackTiming(wait: { target?.cancel() })
        target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: timing))
        #expect(await target?.update(text: "abcdefghijklmnop") == false)
        #expect(editor.keyboardSteps == ["abcdefgh"])
    }

    @Test func finalCaretMoveNeverOverwritesLateUserChanges() async throws {
        for change in 0..<3 {
            let editor = Editor()
            editor.transport = .targetedKeyboard
            editor.finalPasteEnabled = true
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(text: "old ending"))
            editor.afterFinalAcknowledgement = {
                if change == 0 { editor.text += " user" }
                if change == 1 { target.cancel() }
                if change == 2 { editor.selectionSucceeds = false }
            }
            #expect(await target.finish(text: "New ending") == false)
            #expect(editor.finalPastes == ["New"])
            #expect(editor.text.hasPrefix("Before New ending after"))
            #expect(editor.selection == NSRange(location: 10, length: 0))
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

    @Test func structuredPreviewsFreezeCommittedPrefixForBothTransports() async throws {
        for transport in [LiveDictationTextTarget.Transport.axSelectedText, .targetedKeyboard] {
            let editor = Editor()
            editor.transport = transport
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(committedText: "Hello ", tail: "wrld"))
            editor.selectedRanges.removeAll()
            #expect(await target.update(committedText: "Hello ", tail: "world"))
            #expect(await target.update(committedText: "Hello world", tail: " again"))
            #expect(editor.text == "Before Hello world again after")
            #expect(editor.selectedRanges.allSatisfy { $0.location >= 13 })
            let selections = editor.selections
            #expect(await target.update(committedText: "HELLO world", tail: " again") == false)
            #expect(target.isSuspended)
            #expect(editor.selections == selections)
        }
    }

    @Test func finalCleanupCanReviseFrozenCommittedText() async throws {
        for transport in [LiveDictationTextTarget.Transport.axSelectedText, .targetedKeyboard] {
            let editor = Editor()
            editor.transport = transport
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(committedText: "hello ", tail: "world"))
            #expect(await target.finish(text: "Hello, world. "))
            #expect(editor.text == "Before Hello, world.  after")
            #expect(!target.isSuspended)
        }
    }

    @Test func structuredCommitmentsUseExactUTF16AndWholeGraphemeBoundaries() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(committedText: "é ", tail: "tail"))
        #expect(await target.update(committedText: "e\u{301} ", tail: "tail") == false)
        #expect(editor.replacements == 1)
        let splitEditor = Editor()
        let splitTarget = try #require(LiveDictationTextTarget(access: splitEditor.access))
        #expect(await splitTarget.update(committedText: "e", tail: "\u{301}") == false)
        #expect(splitEditor.selections == 0)
    }

    @Test func clearingTailNeverRewritesFrozenKeyboardGrapheme() async throws {
        for transport in [LiveDictationTextTarget.Transport.axSelectedText, .targetedKeyboard] {
            let editor = Editor()
            editor.transport = transport
            var diagnostics: [String] = []
            let target = try #require(LiveDictationTextTarget(access: editor.access,
                onDiagnostic: { diagnostics.append($0) }))
            #expect(await target.update(committedText: "Stable", tail: " tail"))
            let selections = editor.selections
            #expect(await target.update(committedText: "Stable", tail: ""))
            if transport == .targetedKeyboard {
                #expect(editor.selections == selections)
                #expect(editor.text == "Before Stable tail after")
                #expect(diagnostics.last == "preview_deferred_committed_boundary")
            } else {
                #expect(editor.text == "Before Stable after")
                #expect(editor.selectedRanges.last == NSRange(location: 13, length: 5))
            }
            #expect(await target.update(committedText: "Stable", tail: " text"))
            #expect(editor.text == "Before Stable text after")
            #expect(!target.isSuspended)
            target.cancel()
        }
    }

    @Test func longLiveRewriteIsDeferredWithoutAdvancingCommitment() async throws {
        for transport in [LiveDictationTextTarget.Transport.axSelectedText, .targetedKeyboard] {
            let editor = Editor()
            editor.transport = transport
            var diagnostics: [String] = []
            let target = try #require(LiveDictationTextTarget(access: editor.access,
                onDiagnostic: { diagnostics.append($0) }))
            let tail = String(repeating: "a", count: 81)
            // Initial append remains unrestricted even when it exceeds the cap.
            #expect(await target.update(committedText: "Stable ", tail: tail))
            let selections = editor.selections
            #expect(await target.update(committedText: "Stable changed ", tail: "replacement"))
            #expect(editor.selections == selections)
            #expect(editor.text == "Before Stable " + tail + " after")
            #expect(diagnostics.last == "preview_deferred_rewrite_limit")
            // The deferred incoming commitment was never frozen.
            #expect(await target.update(committedText: "Stable ", tail: tail + " append"))
            #expect(editor.text == "Before Stable " + tail + " append after")
            #expect(await target.finish(text: "A clean final sentence. "))
            #expect(editor.text == "Before A clean final sentence.  after")
        }
    }

    @Test func liveRewriteLimitAllowsEightyGraphemesAndLegacyRemainsUnrestricted() async throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(committedText: "", tail: String(repeating: "🦊", count: 80)))
        #expect(await target.update(committedText: "", tail: "short"))
        #expect(editor.text == "Before short after")
        #expect(await target.update(text: String(repeating: "x", count: 100)))
        #expect(await target.update(text: "legacy revision"))
        #expect(editor.text == "Before legacy revision after")
    }

    @Test func keyboardDispatchFailureReportsExactReasonWithoutRetry() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        editor.keyboardFailureAt = 1
        var diagnostics: [String] = []
        let target = try #require(LiveDictationTextTarget(access: editor.access,
            onDiagnostic: { diagnostics.append($0) }))
        #expect(await target.update(text: "hello") == false)
        #expect(diagnostics == ["keyboard_dispatch_event_creation", "keyboard_dispatch_failed"])
        #expect(await target.finish(text: "hello") == false)
        #expect(editor.keyboardSteps == ["h"])
    }

    @Test func keyboardLastMomentValidationReportsTextAndCaretMismatch() async throws {
        for changesText in [true, false] {
            let editor = Editor()
            editor.transport = .targetedKeyboard
            editor.beforeKeyboardValidation = {
                if changesText { editor.text += "user" }
                else { editor.selection.location = 0 }
            }
            var diagnostics: [String] = []
            let target = try #require(LiveDictationTextTarget(access: editor.access,
                onDiagnostic: { diagnostics.append($0) }))
            #expect(await target.update(text: "hello") == false)
            #expect(diagnostics.first == "keyboard_validation_snapshot_changed:textMatches=\(!changesText),caretMatches=\(changesText)")
            #expect(diagnostics.contains("keyboard_dispatch_target_validation_failed"))
            #expect(editor.keyboardSteps.isEmpty)
            #expect(editor.replacements == 0)
        }
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
        #expect(reasons.last == "text_readback_timeout")
        editor.flushReplacement()
        #expect(await target.finish(text: "do not retry") == false)
        #expect(editor.replacements == 1)
    }

    @Test func splitTextAndCaretReadbacksWaitForCompleteAcknowledgement() async throws {
        for transport in [LiveDictationTextTarget.Transport.axSelectedText, .targetedKeyboard] {
            for textFirst in [true, false] {
                let editor = Editor("", selection: NSRange(location: 0, length: 0))
                editor.transport = transport
                editor.replacementTextFirst = textFirst
                editor.replacementCaretFirst = !textFirst
                let clock = PollClock()
                var diagnostics: [String] = []
                let target = try #require(LiveDictationTextTarget(access: editor.access,
                    onDiagnostic: { diagnostics.append($0) }, readbackTiming: clock.timing))
                clock.onWait = {
                    // A second key must not be sent while the first key's text
                    // and caret still disagree. Own notifications must not revoke us.
                    #expect(editor.keyboardSteps.count == (transport == .targetedKeyboard ? clock.ticks : 0))
                    #expect(!target.hasInsertedText || clock.ticks > 1)
                    target.textTargetDidChange()
                    editor.flushSplitReplacement()
                    target.textTargetDidChange()
                }
                #expect(await target.update(text: "I🦊"))
                #expect(editor.text == "I🦊")
                #expect(editor.selection == NSRange(location: 3, length: 0))
                #expect(target.hasInsertedText)
                #expect(!target.isSuspended)
                #expect(clock.ticks == (transport == .targetedKeyboard ? 2 : 1))
                #expect(editor.replacements == (transport == .axSelectedText ? 1 : 0))
                #expect(diagnostics.contains { $0.contains(textFirst ? "text=new" : "text=old") && $0.contains(textFirst ? "caret=old" : "caret=new") })
                target.cancel()
            }
        }
    }

    @Test func splitReadbackTimeoutNeverSendsNextKeyOrRetries() async throws {
        for textFirst in [true, false] {
            let editor = Editor("", selection: NSRange(location: 0, length: 0))
            editor.transport = .targetedKeyboard
            editor.replacementTextFirst = textFirst
            editor.replacementCaretFirst = !textFirst
            let clock = PollClock()
            var diagnostics: [String] = []
            let target = try #require(LiveDictationTextTarget(access: editor.access,
                onDiagnostic: { diagnostics.append($0) }, readbackTiming: clock.timing))
            #expect(await target.update(text: "I am speaking") == false)
            #expect(target.isSuspended)
            #expect(!target.hasInsertedText)
            #expect(clock.ticks == 5)
            #expect(diagnostics.last == "keyboard_text_readback_timeout")
            #expect(diagnostics.count == 2) // One mixed-state diagnostic, then timeout.
            editor.flushSplitReplacement()
            #expect(await target.finish(text: "I am speaking.") == false)
            #expect(editor.keyboardSteps == ["I"])
            #expect(editor.replacements == 0)
        }
    }

    @Test func unrelatedTextOrCaretDuringSplitReadbackStopsImmediately() async throws {
        for changeText in [true, false] {
            let editor = Editor("private", selection: NSRange(location: 7, length: 0))
            editor.transport = .targetedKeyboard
            editor.replacementTextFirst = true
            let clock = PollClock()
            clock.onWait = {
                if changeText { editor.text += " user edit" }
                else { editor.selection = NSRange(location: 0, length: 0) }
            }
            var diagnostics: [String] = []
            let target = try #require(LiveDictationTextTarget(access: editor.access,
                onDiagnostic: { diagnostics.append($0) }, readbackTiming: clock.timing))
            #expect(await target.update(text: "I am speaking") == false)
            #expect(clock.ticks == 1)
            #expect(target.isSuspended)
            #expect(diagnostics.last == "keyboard_text_readback_changed")
            #expect(diagnostics.contains { $0.contains(changeText ? "text=other" : "caret=other") })
            #expect(diagnostics.allSatisfy { !$0.contains("private") && !$0.contains("user edit") && !$0.contains("I am speaking") })
            #expect(await target.update(text: "retry") == false)
            #expect(editor.keyboardSteps == ["I"])
            #expect(editor.replacements == 0)
        }
    }

    @Test func diagnosticOnlyTextDifferencesAreNeverAccepted() async throws {
        for observed in ["i", "I\n"] {
            let editor = Editor("", selection: NSRange(location: 0, length: 0))
            editor.transport = .targetedKeyboard
            editor.afterKeyboard = { editor.text = observed }
            var diagnostics: [String] = []
            let target = try #require(LiveDictationTextTarget(access: editor.access,
                onDiagnostic: { diagnostics.append($0) }))
            #expect(await target.update(text: "I speak") == false)
            #expect(target.isSuspended)
            #expect(diagnostics.contains { $0.contains(observed == "i" ? "caseOnly=true" : "trailingNewlineOnly=true") })
            #expect(diagnostics.last == "keyboard_text_readback_changed")
            #expect(editor.keyboardSteps == ["I"])
        }
    }

    @Test func codexEmptyLineSentinelPolicyIsExplicitAndExact() {
        #expect(LiveDictationTextTarget.allowsEmptyLineSentinelRemoval(for: "com.openai.codex"))
        for bundle in [nil, "com.openai.codex.beta", "com.apple.TextEdit", "COM.OPENAI.CODEX"] {
            #expect(!LiveDictationTextTarget.allowsEmptyLineSentinelRemoval(for: bundle))
        }
    }

    @Test func removedInitialSentinelSupportsFullPreviewRevisionAndFinalCleanup() async throws {
        let editor = Editor("\n", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.allowsEmptyLineSentinelRemoval = true
        editor.removesInitialNewline = true
        var diagnostics: [String] = []
        let target = try #require(LiveDictationTextTarget(access: editor.access,
            onDiagnostic: { diagnostics.append($0) }))
        #expect(await target.update(text: "I am talking"))
        #expect(editor.text == "I am talking")
        #expect(await target.update(text: "I am speaking clearly"))
        #expect(editor.text == "I am speaking clearly")
        #expect(await target.finish(text: "I am speaking clearly. "))
        #expect(editor.text == "I am speaking clearly. ")
        #expect(editor.selection == NSRange(location: editor.text.utf16.count, length: 0))
        #expect(diagnostics == ["keyboard_empty_line_sentinel_removed"])
        #expect(editor.replacements == 0)
        #expect(!target.isSuspended)
    }

    @Test func initialSentinelAlternateWaitsForCaretAndUsesUTF16() async throws {
        let editor = Editor("\n", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.allowsEmptyLineSentinelRemoval = true
        editor.removesInitialNewline = true
        editor.replacementTextFirst = true
        let clock = PollClock()
        var diagnostics: [String] = []
        let target = try #require(LiveDictationTextTarget(access: editor.access,
            onDiagnostic: { diagnostics.append($0) }, readbackTiming: clock.timing))
        clock.onWait = {
            #expect(editor.keyboardSteps.count == clock.ticks)
            editor.flushSplitReplacement()
            target.textTargetDidChange()
        }
        #expect(await target.update(text: "🦊 hi"))
        #expect(editor.text == "🦊 hi")
        #expect(editor.selection == NSRange(location: 5, length: 0))
        #expect(diagnostics.contains { $0.contains("text=alternate") && $0.contains("caret=old") })
        #expect(diagnostics.filter { $0 == "keyboard_empty_line_sentinel_removed" }.count == 1)
        #expect(await target.finish(text: "🦊 Hi. "))
        #expect(editor.text == "🦊 Hi. ")
    }

    @Test func retainedInitialNewlineIsPreservedAcrossPreviewAndFinal() async throws {
        let editor = Editor("\n", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.allowsEmptyLineSentinelRemoval = true
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "I speak"))
        #expect(editor.text == "I speak\n")
        #expect(await target.finish(text: "I speak. "))
        #expect(editor.text == "I speak. \n")
    }

    @Test func sentinelCompatibilityRequiresEligibleCaptureAndKeyboardTransport() async throws {
        let cases: [(String, NSRange, LiveDictationTextTarget.Transport, Bool)] = [
            ("\n", NSRange(location: 0, length: 0), .targetedKeyboard, false),
            ("\n", NSRange(location: 0, length: 0), .axSelectedText, true),
            ("\n", NSRange(location: 1, length: 0), .targetedKeyboard, true),
            ("\n", NSRange(location: 0, length: 1), .targetedKeyboard, true),
            ("\r\n", NSRange(location: 0, length: 0), .targetedKeyboard, true),
            ("\n\n", NSRange(location: 0, length: 0), .targetedKeyboard, true),
            ("existing\n", NSRange(location: 0, length: 0), .targetedKeyboard, true),
        ]
        for (initial, selection, transport, capability) in cases {
            let editor = Editor(initial, selection: selection)
            editor.transport = transport
            editor.allowsEmptyLineSentinelRemoval = capability
            // Simulate removal of preexisting content. Selected newline replacement
            // is naturally valid, so use an unrelated edit for that one case.
            let mutate = { editor.text = selection.length == 1 ? "unexpected" : "I" }
            editor.afterKeyboard = mutate
            editor.afterReplacement = mutate
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(text: "I speak") == false)
            #expect(target.isSuspended)
            #expect(editor.keyboardSteps.count == (transport == .targetedKeyboard ? 1 : 0))
            #expect(editor.replacements == (transport == .axSelectedText ? 1 : 0))
        }
    }

    @Test func retainedSentinelCannotDisappearOnLaterKey() async throws {
        let editor = Editor("\n", selection: NSRange(location: 0, length: 0))
        editor.transport = .targetedKeyboard
        editor.allowsEmptyLineSentinelRemoval = true
        editor.afterKeyboard = {
            if editor.keyboardSteps.count == 2 { editor.text.removeLast() }
        }
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "I speak") == false)
        #expect(target.isSuspended)
        #expect(editor.keyboardSteps == ["I", " "])
        #expect(editor.replacements == 0)
    }

    @Test func alternateSentinelReadbackTimeoutOrCancellationSendsNoMoreKeys() async throws {
        for cancel in [false, true] {
            let editor = Editor("\n", selection: NSRange(location: 0, length: 0))
            editor.transport = .targetedKeyboard
            editor.allowsEmptyLineSentinelRemoval = true
            editor.removesInitialNewline = true
            editor.replacementTextFirst = true
            let clock = PollClock()
            let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
            clock.onWait = { if cancel { target.cancel() } }
            #expect(await target.update(text: "I speak") == false)
            editor.flushSplitReplacement()
            #expect(await target.finish(text: "I speak.") == false)
            #expect(!target.hasInsertedText)
            #expect(editor.keyboardSteps == ["I"])
            #expect(editor.replacements == 0)
        }
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


    @Test func transportPolicyOnlyOptsExactCodexBundleIntoKeyboard() {
        #expect(LiveDictationTextTarget.transport(for: "com.openai.codex") == .targetedPaste)
        for id in [nil, "com.openai.codex.beta", "com.openai.chat", "com.apple.TextEdit"] as [String?] {
            #expect(LiveDictationTextTarget.transport(for: id) == .axSelectedText)
        }
    }

    @Test func chosenKeyboardNeverUsesAcceptedButIneffectiveAXTextSetter() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        editor.delayReplacement = true // AX setter would accept but not update its value.
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "hello"))
        #expect(editor.text == "Before hello after")
        #expect(editor.keyboardSteps == ["h", "e", "l", "l", "o"])
        #expect(editor.replacements == 0)
        #expect(target.hasInsertedText)
    }

    @Test func keyboardAppendPreservesPrefixAndTypesOnlyNewSuffix() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "hello"))
        editor.keyboardSteps.removeAll()
        #expect(await target.update(text: "hello world"))
        #expect(editor.keyboardSteps.joined() == " world")
        #expect(editor.selectedRanges.last == NSRange(location: 12, length: 0))
        #expect(editor.text == "Before hello world after")
    }

    @Test func keyboardRevisionAndShorteningRetypeOneRetainedGraphemeWithoutDeletes() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "hello wrong"))
        editor.keyboardSteps.removeAll()
        #expect(await target.update(text: "hello world"))
        #expect(editor.keyboardSteps.joined() == "orld")
        editor.keyboardSteps.removeAll()
        #expect(await target.finish(text: "hello"))
        #expect(editor.keyboardSteps == ["o"])
        #expect(editor.selectedRanges.last == NSRange(location: 11, length: 7))
        #expect(editor.text == "Before hello after")
        #expect(editor.replacements == 0)
    }

    @Test func keyboardInitialSelectionAndUnicodeUseWholeExactGraphemes() async throws {
        let editor = Editor("🦊 old fin", selection: NSRange(location: 3, length: 3))
        editor.transport = .targetedKeyboard
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "👩🏽‍💻 café"))
        #expect(editor.keyboardSteps.first == "👩🏽‍💻")
        editor.keyboardSteps.removeAll()
        #expect(await target.update(text: "👩🏽‍💻 cafe\u{301}"))
        // Canonical equality must not hide the different UTF-16 representation.
        #expect(editor.keyboardSteps.count == 1)
        #expect(editor.keyboardSteps[0].utf16.elementsEqual("e\u{301}".utf16))
        #expect(editor.text.utf16.elementsEqual("🦊 👩🏽‍💻 cafe\u{301} fin".utf16))
    }

    @Test func keyboardPreflightsAllControlsBeforeAnyMutation() async throws {
        for value in ["safe\nsubmit", "safe\tother", "safe\rsubmit", "safe\u{1B}", "safe\u{7F}", "safe\u{F700}"] {
            let editor = Editor()
            editor.transport = .targetedKeyboard
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(await target.update(text: value) == false)
            #expect(!target.hasAttemptedWrite)
            #expect(editor.selections == 0)
            #expect(editor.keyboardSteps.isEmpty)
            #expect(editor.replacements == 0)
        }
    }

    @Test func multilineKeyboardFinalPreservesAcknowledgedPreview() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "preview"))
        let priorSelections = editor.selections
        let priorSteps = editor.keyboardSteps
        #expect(await target.finish(text: "Cleaned\nparagraph") == false)
        #expect(editor.text == "Before preview after")
        #expect(editor.selections == priorSelections)
        #expect(editor.keyboardSteps == priorSteps)
    }

    @Test func keyboardDispatchFailurePreservesAcknowledgedPrefixAndStops() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        editor.keyboardFailureAt = 3
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "hello") == false)
        #expect(editor.text == "Before he after")
        #expect(editor.keyboardSteps == ["h", "e", "l"])
        #expect(target.hasInsertedText)
        #expect(target.isSuspended)
        #expect(await target.finish(text: "final") == false)
        #expect(editor.replacements == 0)
    }

    @Test func keyboardCancellationAfterDispatchPreventsAnyLaterCharacter() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.afterKeyboard = { target.cancel() }
        #expect(await target.update(text: "hello") == false)
        #expect(editor.keyboardSteps == ["h"])
        #expect(editor.text == "Before h after")
        #expect(!target.hasInsertedText) // A dispatched event was not acknowledged.
        #expect(await target.finish(text: "final") == false)
        #expect(editor.replacements == 0)
    }

    @Test func failedAcknowledgementNeverClaimsInsertionOrSwitchesTransport() async throws {
        for transport in [LiveDictationTextTarget.Transport.axSelectedText, .targetedKeyboard] {
            let editor = Editor()
            let clock = PollClock()
            editor.transport = transport
            editor.delayReplacement = true
            editor.keyboardNoOp = true
            let target = try #require(LiveDictationTextTarget(access: editor.access, readbackTiming: clock.timing))
            #expect(await target.update(text: "hello") == false)
            #expect(!target.hasInsertedText)
            #expect(target.hasAttemptedWrite)
            #expect(target.isSuspended)
            #expect(await target.finish(text: "final") == false)
            #expect(editor.replacements == (transport == .axSelectedText ? 1 : 0))
            #expect(editor.keyboardSteps.count == (transport == .targetedKeyboard ? 1 : 0))
        }
    }

    @Test func emptyHypothesisPreservesAlreadyInsertedKeyboardText() async throws {
        let editor = Editor()
        editor.transport = .targetedKeyboard
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(await target.update(text: "retain"))
        #expect(await target.update(text: ""))
        #expect(editor.text == "Before retain after")
        #expect(editor.selections == 1)
    }

}
