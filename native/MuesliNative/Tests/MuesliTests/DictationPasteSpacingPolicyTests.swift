import Testing
@testable import MuesliNativeApp

@Suite("Dictation paste spacing policy")
struct DictationPasteSpacingPolicyTests {
    @Test("separate dictations leave sentence spacing at the cursor", arguments: [
        ("Okay, transcribing whether this adds a space after the punctuation or not.", " "),
        ("So that we can start immediately.", " "),
        ("Yeah, it is not seeming to add any punctuation after the full stop.", " "),
        ("¿Qué pasa?", " "), ("Ça va!", " "), ("Да.", " "), ("Ναι.", " "),
        ("حقاً؟", " "), ("ہاں۔", " "), ("כן.", " "), ("है।", " "),
        ("है॥", " "), ("হয়।", " "), ("ஆம்.", " "), ("จบ!", " "),
        ("끝.", " "), ("He said “yes.”", " "), ("(Done.)", " "),
        ("Fin…", " "), ("Fin...", " "), ("U.S.", " "),
        ("结束。", ""), ("終わり！", ""), ("「次です。」", ""), ("中文.", ""),
        ("中文2026。", ""), ("끝2026.", " "),
        ("Done. ", ""), ("Done.\n", ""), ("Done.\u{00A0}", ""),
        ("3.14", ""), ("example.com", ""), ("unfinished", ""),
        ("", ""), (".", ""), ("?!", ""),
    ])
    func trailingSentenceSpace(text: String, expected: String) {
        #expect(DictationPasteSpacing.trailingSeparator(after: text) == expected)
    }
}
