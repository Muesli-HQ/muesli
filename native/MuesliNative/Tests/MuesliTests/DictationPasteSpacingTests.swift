import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Dictation paste spacing")
@MainActor
struct DictationPasteSpacingTests {
    @Test("successive dictations are separated without changing their raw text")
    func successiveDictations() async {
        let chunks = [
            "Okay, transcribing whether this adds a space after the punctuation or not.",
            "So that we can start immediately.",
            "Yeah, it is not seeming to add any punctuation after the full stop.",
        ]
        var inserted = ""
        for text in chunks {
            inserted += await paste(text, dictation: true)
        }
        #expect(inserted == chunks.joined(separator: " ") + " ")
        #expect(chunks.allSatisfy { $0.last == "." })
    }

    @Test("normal paste remains verbatim")
    func verbatimPaste() async {
        #expect(await paste("Quill output.", dictation: false) == "Quill output.")
    }

    @Test("dictation does not double existing spacing or pad CJK", arguments: ["Done. ", "Done.\n", "结束。", "終わり。"])
    func preserveFormatting(text: String) async {
        #expect(await paste(text, dictation: true) == text)
    }

    /// A private pasteboard and injected dispatcher exercise production staging
    /// and restoration without sending keystrokes or touching the real clipboard.
    private func paste(_ text: String, dictation: Bool) async -> String {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("muesli-spacing-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original clipboard", forType: .string)
        var delivered = ""
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PasteController.paste(
                text: text,
                appendDictationSentenceSpace: dictation,
                pasteboard: pasteboard,
                requireStagedClipboardOwnership: true,
                targetApplicationProvider: { nil },
                simulatePasteAction: {
                    delivered = pasteboard.string(forType: .string) ?? ""
                    return true
                },
                onClipboardSettled: { continuation.resume() }
            )
        }
        #expect(pasteboard.string(forType: .string) == "original clipboard")
        return delivered
    }
}
