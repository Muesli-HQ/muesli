import Testing
@testable import MuesliNativeApp

@Suite("Dictionary import parser")
struct DictionaryImportParserTests {
    @Test("parses plain terms one per line")
    func parsesPlainTerms() {
        let words = DictionaryImportParser.parse("""
        Skriber
        Nabla
        # ignored
        """)

        #expect(words.map(\.word) == ["Skriber", "Nabla"])
        #expect(words.allSatisfy { $0.replacement == nil })
    }

    @Test("parses arrows csv and threshold")
    func parsesStructuredLines() {
        let words = DictionaryImportParser.parse("""
        word,replacement,threshold
        Kvex,Caivex,0.78
        open telemetry -> OpenTelemetry
        Suki\tSuki AI\t0.91
        """)

        #expect(words.count == 3)
        #expect(words[0].word == "Kvex")
        #expect(words[0].replacement == "Caivex")
        #expect(words[0].matchingThreshold == 0.78)
        #expect(words[1].word == "open telemetry")
        #expect(words[1].replacement == "OpenTelemetry")
        #expect(words[2].word == "Suki")
        #expect(words[2].replacement == "Suki AI")
        #expect(words[2].matchingThreshold == 0.91)
    }

    @Test("parses quoted csv commas")
    func parsesQuotedCSVCommas() {
        let words = DictionaryImportParser.parse("\"Smith, Robert\",\"Dr. Robert Smith\"")

        #expect(words.count == 1)
        #expect(words[0].word == "Smith, Robert")
        #expect(words[0].replacement == "Dr. Robert Smith")
    }
}
