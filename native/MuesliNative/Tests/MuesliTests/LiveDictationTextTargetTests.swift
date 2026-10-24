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
        var replacements = 0
        var selections = 0

        init(_ text: String = "Before  after", selection: NSRange = NSRange(location: 7, length: 0)) {
            self.text = text
            self.selection = selection
        }

        var access: LiveDictationTextTarget.Access {
            .init(snapshot: { [self] in .init(text: text, selection: selection) },
                  isFocused: { [self] in focused },
                  select: { [self] range in
                      selections += 1
                      guard selectionSucceeds else { return false }
                      selection = range
                      afterSelect?()
                      return true
                  }, replaceSelection: { [self] replacement in
                      replacements += 1
                      // Simulate an IPC call whose error does not prove no mutation.
                      text = (text as NSString).replacingCharacters(in: selection, with: replacement)
                      selection = NSRange(location: selection.location + (replacement as NSString).length, length: 0)
                      if corruptReadback { text += "!" }
                      afterReplacement?()
                      return replacementSucceeds
                  })
        }
    }

    @Test func revisesOnlyOwnedRangeAndFinishes() throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(target.update(text: "yellow"))
        #expect(target.update(text: "hello world"))
        #expect(target.finish(text: "Hello, world. "))
        #expect(editor.text == "Before Hello, world.  after")
        #expect(target.hasInsertedText)
        #expect(target.hasAttemptedWrite)
        #expect(!target.update(text: "late"))
        #expect(editor.replacements == 3)
    }

    @Test func replacesInitialSelectionAndHandlesUTF16() throws {
        let editor = Editor("🦊 old fin", selection: NSRange(location: 3, length: 3))
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(target.update(text: "👩🏽‍💻 नमस्ते"))
        #expect(editor.text == "🦊 👩🏽‍💻 नमस्ते fin")
        #expect(target.update(text: "😀 café"))
        #expect(editor.text == "🦊 😀 café fin")
        #expect(editor.selection == NSRange(location: 3 + ("😀 café" as NSString).length, length: 0))
    }

    @Test func emptyInitialHypothesisPreservesSelection() throws {
        let editor = Editor("selected", selection: NSRange(location: 0, length: 8))
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(target.update(text: ""))
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

    @Test func focusLossPermanentlySuspends() throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(target.update(text: "first"))
        editor.focused = false
        #expect(!target.update(text: "wrong app"))
        editor.focused = true
        #expect(!target.finish(text: "back again"))
        #expect(target.isSuspended)
        #expect(editor.text == "Before first after")
    }

    @Test func userEditOrCaretMoveStopsWrites() throws {
        for changesText in [true, false] {
            let editor = Editor()
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(target.update(text: "first"))
            if changesText { editor.text += "user edit" } else { editor.selection.location = 0 }
            let before = editor.text
            #expect(!target.update(text: "overwrite"))
            #expect(target.isSuspended)
            #expect(editor.text == before)
            #expect(editor.replacements == 1)
        }
    }

    @Test func canonicallyEquivalentUserEditStillRevokesOwnership() throws {
        let editor = Editor("é ", selection: NSRange(location: 2, length: 0))
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.text = "e\u{301} "
        #expect(!target.update(text: "hello"))
        #expect(target.isSuspended)
        #expect(editor.replacements == 0)
    }

    @Test func ownReentrantAndDelayedNotificationsDoNotSuspend() throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.afterSelect = { target.textTargetDidChange() }
        editor.afterReplacement = { target.textTargetDidChange() }
        #expect(target.update(text: "first"))
        target.textTargetDidChange()
        #expect(target.update(text: "revision"))
        #expect(!target.isSuspended)
        #expect(editor.text == "Before revision after")
        // A later external change is observed even without another ASR update.
        editor.selection.location = 0
        target.textTargetDidChange()
        #expect(target.isSuspended)
    }

    @Test func cancellationDuringSelectionPreventsTextWrite() throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.afterSelect = { target.cancel() }
        #expect(!target.update(text: "late"))
        #expect(editor.replacements == 0)
    }

    @Test func focusLossBetweenSelectionAndTextPreventsReplacement() throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        editor.afterSelect = { editor.focused = false }
        #expect(!target.update(text: "unsafe"))
        #expect(target.hasAttemptedWrite)
        #expect(target.isSuspended)
        #expect(editor.replacements == 0)
    }

    @Test func failedOrMismatchedWritesAreNeverRetried() throws {
        for readbackFailure in [true, false] {
            let editor = Editor()
            editor.corruptReadback = readbackFailure
            editor.replacementSucceeds = readbackFailure
            let target = try #require(LiveDictationTextTarget(access: editor.access))
            #expect(!target.update(text: "possibly inserted"))
            #expect(target.hasAttemptedWrite)
            #expect(target.isSuspended)
            #expect(!target.finish(text: "duplicate"))
            #expect(editor.replacements == 1)
        }
    }

    @Test func failedSelectionStopsBeforeReplacement() throws {
        let editor = Editor()
        editor.selectionSucceeds = false
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(!target.update(text: "hello"))
        #expect(target.hasAttemptedWrite)
        #expect(target.isSuspended)
        #expect(editor.replacements == 0)
    }

    @Test func cancellationLeavesInsertedTextAndRejectsLateOutput() throws {
        let editor = Editor()
        let target = try #require(LiveDictationTextTarget(access: editor.access))
        #expect(target.update(text: "keep"))
        target.cancel()
        #expect(!target.update(text: "late"))
        #expect(!target.finish(text: "later"))
        #expect(editor.text == "Before keep after")
    }

    @Test func newSessionRetiresOldOwnership() throws {
        let first = Editor()
        let old = try #require(LiveDictationTextTarget(access: first.access))
        let second = Editor()
        let new = try #require(LiveDictationTextTarget(access: second.access))
        #expect(!old.update(text: "old"))
        #expect(new.update(text: "new"))
        #expect(first.replacements == 0)
    }
}
