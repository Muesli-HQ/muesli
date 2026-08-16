import Testing
@testable import MuesliNativeApp

@Suite("Dictation attribution policy")
struct DictationAttributionPolicyTests {
    @Test("standard and streaming pasted dictations retain attribution")
    func pastedDictationsAreAttributed() {
        #expect(DictationAttributionPolicy.shouldPersist(
            isPasteOutput: true,
            source: "dictation",
            text: "Standard result"
        ))
        #expect(DictationAttributionPolicy.shouldPersist(
            isPasteOutput: true,
            source: "dictation",
            text: "Streaming result"
        ))
    }

    @Test("voice notes CUA iPhone and empty results remain unattributed")
    func excludedCaptureKindsAreNotAttributed() {
        #expect(!DictationAttributionPolicy.shouldPersist(
            isPasteOutput: false,
            source: "dictation",
            text: "Voice note"
        ))
        #expect(!DictationAttributionPolicy.shouldPersist(
            isPasteOutput: true,
            source: "cua",
            text: "Open Notes"
        ))
        #expect(!DictationAttributionPolicy.shouldPersist(
            isPasteOutput: true,
            source: "ios",
            text: "Remote dictation"
        ))
        #expect(!DictationAttributionPolicy.shouldPersist(
            isPasteOutput: true,
            source: "dictation",
            text: "   "
        ))
    }
}
