import Testing
import AppKit
@testable import MuesliNativeApp

// .serialized: some tests still post keyboard events into the active session.
@Suite("PasteController — clipboard-preserving paste and keystroke simulation", .serialized)
struct PasteControllerTests {

    private let clipboardPollInterval: TimeInterval = 0.05
    private let clipboardRestoreTimeout: TimeInterval = 2.0

    // MARK: - typeText tests

    @Test("typeText with empty string does not crash")
    func typeTextEmpty() {
        // Early-return guard: no CGEvents posted, no clipboard access
        PasteController.typeText("")
    }

    @Test("typeText does not modify the system clipboard")
    func typeTextPreservesClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("clipboard-sentinel", forType: .string)

        // Post a single space via CGEvent (minimal side-effect in test runner)
        PasteController.typeText(" ")

        // Clipboard must be unchanged — this is the whole point of typeText
        #expect(pasteboard.string(forType: .string) == "clipboard-sentinel")
    }

    @Test("common ASCII text uses physical keyboard path")
    func commonASCIIUsesPhysicalKeyboardPath() {
        #expect(PasteController.canTypeUsingPhysicalKeys("Hello, world! 123"))
        #expect(PasteController.canTypeUsingPhysicalKeys("this has been created using computer use"))
        #expect(!PasteController.canTypeUsingPhysicalKeys("नमस्ते"))
    }

    @Test("UTF-16 encoding of SentencePiece leading-space deltas is correct")
    func sentencePieceLeadingSpaceUTF16() {
        // Nemotron streaming produces " word" (SentencePiece ▁ → " ").
        // typeText iterates Character.utf16, so verify round-trip is exact.
        let delta = " hello"
        let utf16 = Array(delta.utf16)
        // First code unit must be a space
        #expect(utf16.first == UInt16((" " as Unicode.Scalar).value))
        // All BMP characters: count == Swift character count
        #expect(utf16.count == delta.count)
        // Full round-trip
        let roundTripped = utf16.map { Character(Unicode.Scalar($0)!) }
        #expect(String(roundTripped) == delta)
    }

    @Test("UTF-16 round-trip for multi-word streaming deltas")
    func multiWordDeltaEncoding() {
        let deltas = [" world", " how are you", " testing one two"]
        for delta in deltas {
            let utf16 = Array(delta.utf16)
            let decoded = String(utf16.map { Character(Unicode.Scalar($0)!) })
            #expect(decoded == delta, "Round-trip failed for: \(delta)")
        }
    }

    // MARK: - paste shortcut flags

    @Test("⌘V maps to the command modifier only")
    func commandVFlags() {
        #expect(PasteController.eventFlags(for: .commandV) == .maskCommand)
    }

    @Test("⌘⇧V maps to command + shift modifiers")
    func commandShiftVFlags() {
        #expect(PasteController.eventFlags(for: .commandShiftV) == [.maskCommand, .maskShift])
    }

    @Test("paste honors a non-default shortcut and still stages text on the clipboard")
    func pasteWithShortcutStagesText() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        var simulated = false
        PasteController.paste(
            text: "dictated text",
            pasteboard: pasteboard,
            shortcut: .commandShiftV,
            simulatePasteAction: { simulated = true }
        )

        #expect(pasteboard.string(forType: .string) == "dictated text")
        _ = await waitForClipboardString(in: pasteboard, expected: "original")
        #expect(simulated)
    }

    // MARK: - paste() clipboard restoration

    @Test("paste with empty string is a no-op")
    func pasteEmptyIsNoOp() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "", pasteboard: pasteboard, simulatePasteAction: {})

        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("paste temporarily writes text to clipboard for Cmd+V")
    func pasteWritesTextToClipboard() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: {})

        // Immediately after paste(), the clipboard holds the dictation text
        // (restoration happens asynchronously after ~500ms)
        #expect(pasteboard.string(forType: .string) == "dictated text")

        _ = await waitForClipboardString(in: pasteboard, expected: "original")
    }

    @Test("paste restores clipboard after delay")
    func pasteRestoresClipboard() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("user-copied-text", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: {})

        let restored = await waitForClipboardString(in: pasteboard, expected: "user-copied-text")

        #expect(restored == "user-copied-text")
    }

    @Test("paste restores empty clipboard state")
    func pasteRestoresEmptyClipboard() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: {})

        let restored = await waitForClipboardString(in: pasteboard, expected: nil)

        #expect(restored == nil)
    }

    @Test("paste restores multi-item clipboard")
    func pasteRestoresMultiItemClipboard() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        // Write two distinct items to the clipboard (e.g., Finder multi-file copy)
        let item1 = NSPasteboardItem()
        item1.setString("item-one", forType: .string)
        let item2 = NSPasteboardItem()
        item2.setString("item-two", forType: .string)
        pasteboard.writeObjects([item1, item2])

        let countBefore = pasteboard.pasteboardItems?.count ?? 0
        #expect(countBefore == 2)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: {})

        let (countAfter, texts) = await waitForClipboardItems(
            in: pasteboard,
            expectedCount: 2,
            expectedStrings: ["item-one", "item-two"]
        )

        #expect(countAfter == 2)
        #expect(texts == ["item-one", "item-two"])
    }

    @Test("stale paste restore does not overwrite newer clipboard contents")
    func stalePasteRestoreDoesNotOverwriteNewerClipboardContents() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: {})
        try await Task.sleep(nanoseconds: 100_000_000)

        pasteboard.clearContents()
        pasteboard.setString("user-copied-after-paste", forType: .string)

        try await Task.sleep(nanoseconds: 700_000_000)

        #expect(pasteboard.string(forType: .string) == "user-copied-after-paste")
    }

    private func makePasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("com.muesli.tests.PasteController.\(UUID().uuidString)")
        return NSPasteboard(name: name)
    }

    private func waitForClipboardString(in pasteboard: NSPasteboard, expected: String?) async -> String? {
        await withCheckedContinuation { continuation in
            let deadline = Date().addingTimeInterval(clipboardRestoreTimeout)
            var poll: (() -> Void)?
            poll = {
                let current = pasteboard.string(forType: .string)
                if current == expected || Date() >= deadline {
                    continuation.resume(returning: current)
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + clipboardPollInterval) {
                    poll?()
                }
            }

            DispatchQueue.main.async {
                poll?()
            }
        }
    }

    private func waitForClipboardItems(
        in pasteboard: NSPasteboard,
        expectedCount: Int,
        expectedStrings: [String]
    ) async -> (Int, [String]) {
        await withCheckedContinuation { continuation in
            let deadline = Date().addingTimeInterval(clipboardRestoreTimeout)
            var poll: (() -> Void)?
            poll = {
                let items = pasteboard.pasteboardItems ?? []
                let count = items.count
                let strings = items.compactMap { $0.string(forType: .string) }
                if (count == expectedCount && strings == expectedStrings) || Date() >= deadline {
                    continuation.resume(returning: (count, strings))
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + clipboardPollInterval) {
                    poll?()
                }
            }

            DispatchQueue.main.async {
                poll?()
            }
        }
    }
}
