import Foundation
import MuesliCore
import Testing

@Suite("Meeting speaker identity")
struct MeetingSpeakerStateTests {
    @Test func manualAssignmentAndDeclineSurviveRoundtrip() throws {
        var state = fixture()
        let key = state.speakers[0].key
        let assignedAccessibilityName = state.assign(.init(name: "Example", provenance: .accessibility), to: key)
        #expect(assignedAccessibilityName)
        state.declineAutomaticName(for: key)
        let reassignedDeclinedName = state.assign(.init(name: "Example", provenance: .accessibility), to: key)
        #expect(!reassignedDeclinedName)
        let assignedManualName = state.assign(.init(name: "手動", provenance: .manual), to: key)
        #expect(assignedManualName)
        let replacedManualName = state.assign(.init(name: "Other", provenance: .voice), to: key)
        #expect(!replacedManualName)
        let restored = try JSONDecoder().decode(MeetingSpeakerState.self, from: JSONEncoder().encode(state))
        #expect(restored.render() == "[00:00:01] 手動: Keep these words.")
        #expect(restored.speakers[0].key == key)
        #expect(restored.speakers[0].rank == 1)
        #expect(restored.speakers[0].history.count == 1)
    }

    @Test func legacyTranscriptRenderingMatchesSavedColonLabels() {
        var state = fixture()
        let key = state.speakers[0].key
        _ = state.assign(.init(name: "Team: Example", provenance: .manual), to: key)
        let legacy = state.renderLegacy()

        #expect(legacy == "[00:00:01] Team: Example: Keep these words.")
        #expect(state.matchesTranscript(legacy))
        #expect(state.matchesTranscriptDigest(MeetingSpeakerState.digest(legacy)))
    }

    @Test func duplicateReservedAndSuffixNamesStayDistinct() {
        var state = fixture()
        let names = ["Example", "Example", "Example (2)", "You", "you", "Speaker 1", "👩‍💻: 長い名前"]
        state.speakers = names.enumerated().map { index, name in
            .init(key: .init(epoch: state.epoch, channel: .system, clusterID: "c\(index)"),
                  rank: index + 1, fallbackLabel: "Speaker \(index + 1)",
                  assignment: .init(name: name, provenance: .manual))
        }
        let labels = state.labels
        #expect(Set(labels.values.map { $0.lowercased() }).count == names.count)
        #expect(labels[state.speakers[6].key] == "👩‍💻: 長い名前")
        #expect(labels[state.speakers[3].key] != "You")
        #expect(labels[state.speakers[5].key] != "Speaker 1")
    }

    @Test func controlNamesCannotInjectRecords() {
        for scalar in ["\n", "\r", "\u{2028}", "\u{2029}", "\u{0000}", "\u{202E}", "\u{2063}"] {
            var state = fixture()
            _ = state.assign(.init(name: "A\(scalar)B", provenance: .manual), to: state.speakers[0].key)
            #expect(state.render().split(separator: "\n").count == 1)
            #expect(!state.labels.values.joined().contains(scalar))
            #expect(state.turns[0].text == "Keep these words.")
        }
    }

    @Test func modelFacingTranscriptUnescapesOnlySpeakerLabels() {
        let stored = MeetingSpeakerState.renderTranscriptTurn(
            timestamp: "00:00:01", speaker: "Team: Example\\Host", text: #"Keep \: speech\\literal"#
        )
        let readable = #"[00:00:01] Team: Example\Host: Keep \: speech\\literal"#

        #expect(MeetingSpeakerState.modelFacingTranscript(stored) == readable)
        #expect(MeetingSpeakerState.modelFacingTranscript(readable) == readable)
    }

    @Test func modelFacingTranscriptPreservesLegacyLiteralBackslashBeforeColon() {
        let legacy = MeetingSpeakerState.renderLegacyTranscriptTurn(
            timestamp: "00:00:01", speaker: "Team\\: Room", text: "Keep these words."
        )

        #expect(MeetingSpeakerState.modelFacingTranscript(legacy) == legacy)
    }

    @Test func transcriptEditingShowsReadableNamesAndPreservesTheirBoundary() {
        let stored = MeetingSpeakerState.renderTranscriptTurn(
            timestamp: "00:00:01", speaker: "Team: Example", text: "Ship Friday."
        )
        let editor = MeetingSpeakerState.transcriptForEditing(stored)
        let display = "[00:00:01] Team: Example: Ship Friday."
        #expect(editor == "[00:00:01] Team: Example\u{2063}: Ship Friday.")
        #expect(MeetingSpeakerState.displayTranscript(fromEditingTranscript: editor) == display)
        #expect(MeetingSpeakerState.storedTranscript(fromEditingTranscript: editor) == stored)

        let renamedEditor = editor.replacingOccurrences(of: "Team: Example", with: "Team: Product")
        #expect(MeetingSpeakerState.storedTranscript(fromEditingTranscript: renamedEditor) ==
            MeetingSpeakerState.renderTranscriptTurn(
                timestamp: "00:00:01", speaker: "Team: Product", text: "Ship Friday."
            ))

        let editedWords = editor.replacingOccurrences(of: "Ship Friday.", with: "Ship Monday.")
        #expect(MeetingSpeakerState.storedTranscript(fromEditingTranscript: editedWords) ==
            MeetingSpeakerState.renderTranscriptTurn(
                timestamp: "00:00:01", speaker: "Team: Example", text: "Ship Monday."
            ))
    }

    @Test func modelFacingTranscriptLeavesNonCanonicalBackslashTextAlone() {
        let speech = #"[00:00:01] Transcript text\q: words"#

        #expect(MeetingSpeakerState.modelFacingTranscript(speech) == speech)
    }

    @Test func aggregatesCannotBeNamed() {
        var state = fixture()
        state.speakers[0].isAssignable = false
        let assignedAggregateName = state.assign(.init(name: "Example", provenance: .manual), to: state.speakers[0].key)
        #expect(!assignedAggregateName)
    }

    private func fixture() -> MeetingSpeakerState {
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "cluster")
        return .init(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
                     turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Keep these words.")])
    }
}
