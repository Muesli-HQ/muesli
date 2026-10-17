import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting speaker corrections")
struct MeetingSpeakerEditingTests {
    @Test func mergeChainKeepsSurvivorAndUndoKeepsRevision() {
        var state = fixture()
        let keys = state.speakers.map(\.key), original = state.turns
        let renamedSurvivor = state.correct(.rename(keys[2], "Survivor"))
        #expect(renamedSurvivor)
        let mergedFirst = state.correct(.merge(keys[0], into: keys[1]))
        #expect(mergedFirst)
        let mergedSecond = state.correct(.merge(keys[1], into: keys[2]))
        #expect(mergedSecond)
        #expect(state.canonicalKey(for: keys[0]) == keys[2])
        #expect(state.labels[keys[2]] == "Survivor")
        #expect(state.turns.allSatisfy { $0.speaker == keys[2] })
        state.revision = 42
        let undidLastMerge = state.correct(.undo)
        #expect(undidLastMerge)
        #expect(state.revision == 42)
        let undidFirstMerge = state.correct(.undo)
        #expect(undidFirstMerge)
        #expect(state.turns == original)
        #expect(state.isValid)
    }

    @Test func mergingSelfIntoRemoteKeepsTargetColourAndTransfersSelfMarker() {
        let epoch = UUID()
        let you = MeetingSpeaker(
            key: .init(epoch: epoch, channel: .microphone, clusterID: "source"),
            rank: 1, fallbackLabel: "You", isSelf: true
        )
        let remote = MeetingSpeaker(
            key: .init(epoch: epoch, channel: .system, clusterID: "remote"),
            rank: 2, fallbackLabel: "Speaker 1"
        )
        var state = MeetingSpeakerState(epoch: epoch, speakers: [you, remote], turns: [
            .init(speaker: you.key, timestamp: "00:00:01", start: 1, end: 2, text: "Local voice"),
            .init(speaker: remote.key, timestamp: "00:00:02", start: 2, end: 3, text: "Remote voice"),
        ])
        let targetColour = MeetingSpeakerPalette.colour(for: remote.key, isSelf: remote.isSelf, isPerson: true)

        let mergedSelf = state.correct(.merge(you.key, into: remote.key))
        #expect(mergedSelf)

        let survivor = state.speakers.first { $0.key == remote.key }
        #expect(survivor?.isSelf == true)
        #expect(survivor?.paletteIsSelf == false)
        #expect(MeetingSpeakerPalette.colour(
            for: survivor?.key,
            isSelf: survivor?.paletteIsSelf ?? survivor?.isSelf ?? false,
            isPerson: true
        ) == targetColour)
        let undidMerge = state.correct(.undo)
        #expect(undidMerge)
        #expect(state.speakers.first { $0.key == you.key }?.isSelf == true)
        #expect(state.speakers.first { $0.key == remote.key }?.paletteIsSelf == nil)
    }

    @Test func selectedWordsPreserveExactBytesAndUnrelatedTurns() {
        var state = fixture(text: "Cafe\u{301} 👩‍💻  words\nend")
        let original = state.turns[0], unaffected = state.turns[1]
        let range = (original.text as NSString).range(of: "👩‍💻  words")
        let reassignedSelection = state.correct(.reassignSelection(original.id, range, to: state.speakers[1].key))
        #expect(reassignedSelection)
        #expect(Array(state.turns.dropLast().map(\.text).joined().utf8) == Array(original.text.utf8))
        #expect(state.turns.last == unaffected)
        #expect(state.turns.dropLast().allSatisfy { $0.start == original.start && $0.end == original.end && $0.sampleEligible == false })
        let undidSelection = state.correct(.undo)
        #expect(undidSelection)
        #expect(state.turns == [original, unaffected])
    }

    @Test func invalidSelectionsAreAtomicAndFullSelectionKeepsID() {
        var state = fixture(text: "e\u{301} 👩‍💻")
        let original = state, turn = state.turns[0], target = state.speakers[1].key
        for range in [NSRange(location: 0, length: 0), NSRange(location: Int.max, length: 2),
                      NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)] {
            let reassignedSelection = state.correct(.reassignSelection(turn.id, range, to: target))
            #expect(!reassignedSelection)
            #expect(state == original)
        }
        let reassignedWholeTurn = state.correct(.reassignSelection(turn.id, NSRange(location: 0, length: turn.text.utf16.count), to: target))
        #expect(reassignedWholeTurn)
        #expect(state.turns[0].id == turn.id)
        #expect(state.turns[0].text == turn.text)
    }

    @Test func sampleBoundsOverlapAndSearch() {
        var state = fixture(text: "Search words")
        let key = state.speakers[0].key
        #expect(state.sampleRange(for: key)?.duration == 6)
        let renamed = state.correct(.rename(key, "Example"))
        #expect(renamed)
        #expect(state.matchingTurns(query: "example").count == 1)
        #expect(state.matchingTurns(query: "search").count == 1)
        state.turns.append(.init(speaker: state.speakers[1].key, timestamp: "00:00:01", start: 1, end: 3, text: "Overlap"))
        #expect(state.sampleRange(for: key) == nil)
    }

    private func fixture(text: String = "Original words") -> MeetingSpeakerState {
        let epoch = UUID()
        let speakers = (0..<3).map { index in MeetingSpeaker(key: .init(epoch: epoch, channel: .system, clusterID: "c\(index)"), rank: index + 1, fallbackLabel: "Speaker \(index + 1)") }
        return .init(epoch: epoch, speakers: speakers,
            turns: [.init(speaker: speakers[0].key, timestamp: "00:00:00", start: 0, end: 10, text: text),
                    .init(speaker: speakers[1].key, timestamp: "00:00:12", start: 12, end: 14, text: "Unchanged")])
    }
}

extension MeetingSpeakerEditingTests {
    @Test func manualCreationResetDeclineAndUndoStayReversible() {
        var state = fixture()
        let key = state.speakers[0].key
        let assignedName = state.assign(.init(name: "Example", provenance: .accessibility), to: key)
        #expect(assignedName)
        let declinedName = state.correct(.declineName(key))
        #expect(declinedName)
        let reassignedDeclinedName = state.assign(.init(name: "Example", provenance: .accessibility), to: key)
        #expect(!reassignedDeclinedName)
        let undidDecline = state.correct(.undo)
        #expect(undidDecline)
        #expect(state.speakers[0].assignment?.name == "Example")
        let resetName = state.correct(.resetName(key))
        #expect(resetName)
        #expect(state.speakers[0].assignment == nil)
        let undidReset = state.correct(.undo)
        #expect(undidReset)
        let addedSpeaker = state.correct(.addSpeaker("Example", .system))
        #expect(addedSpeaker)
        #expect(state.activeSpeakers.count == 4)
        #expect(state.speakers[0].key != state.speakers[3].key)
        let undidAdd = state.correct(.undo)
        #expect(undidAdd)
        #expect(state.activeSpeakers.count == 3)
    }

    @Test func assigningWordsToCurrentSpeakerDoesNotSplitText() {
        var state = fixture()
        let before = state
        let turn = state.turns[0]
        let reassignedToCurrentSpeaker = state.correct(.reassignSelection(turn.id, NSRange(location: 0, length: 8), to: turn.speaker))
        #expect(!reassignedToCurrentSpeaker)
        #expect(state == before)
    }

    @Test @MainActor func assignmentMenuTargetsExcludeCurrentSpeaker() {
        let state = fixture()
        let turn = state.turns[0]

        let targets = MeetingSpeakerEditorModel.assignableSpeakers(state.activeSpeakers, for: turn)

        #expect(targets.map(\.key) == state.activeSpeakers.map(\.key).filter { $0 != turn.speaker })
    }

    @Test func selectionResetIsAppliedWhenTranscriptTextIsUnchanged() {
        let reset = MeetingSpeakerSelectionState.rangeToApply(
            binding: NSRange(location: 0, length: 0),
            current: NSRange(location: 6, length: 5),
            text: "hello world"
        )

        #expect(reset == NSRange(location: 0, length: 0))
        #expect(MeetingSpeakerSelectionState.rangeToApply(
            binding: NSRange(location: 0, length: 0),
            current: NSRange(location: 0, length: 0),
            text: "hello world"
        ) == nil)
    }

    @MainActor @Test func editorSearchReturnsMatchingTurns() async {
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "search")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
            turns: [
                .init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Search target"),
                .init(speaker: key, timestamp: "00:00:02", start: 2, end: 3, text: "Other words"),
            ])
        let version = MeetingTranscriptVersion(generation: 1, digest: "search-fixture")
        let model = MeetingSpeakerEditorModel()
        model.snapshot = MeetingSpeakerSnapshot(state: state, version: version, summaryIsStale: false)

        await model.updateMatchingTurns(.init(query: "target", version: version, speakerRevision: state.revision))

        #expect(model.matchingTurns.map(\.text) == ["Search target"])
    }

    @MainActor @Test func editorSearchRefreshesAfterGenericSpeakerReassignment() async {
        let epoch = UUID()
        let originalKey = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "owner")
        let reassignedKey = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "guest")
        let version = MeetingTranscriptVersion(generation: 1, digest: "same-transcript")
        var state = MeetingSpeakerState(epoch: epoch, speakers: [
            .init(key: originalKey, rank: 1, fallbackLabel: "Microphone"),
            .init(key: reassignedKey, rank: 2, fallbackLabel: "Microphone"),
        ], turns: [
            .init(speaker: originalKey, timestamp: "00:00:01", start: 1, end: 2, text: "Shared audio"),
        ])
        let model = MeetingSpeakerEditorModel()
        model.snapshot = MeetingSpeakerSnapshot(state: state, version: version, summaryIsStale: false)

        let originalSearch = MeetingSpeakerSearchInput(query: "Microphone", version: version, speakerRevision: state.revision)
        await model.updateMatchingTurns(originalSearch)
        #expect(model.matchingTurns.map(\.speaker) == [originalKey])

        let reassigned = state.correct(.reassign(state.turns[0].id, to: reassignedKey))
        #expect(reassigned)
        state.revision += 1
        model.snapshot = MeetingSpeakerSnapshot(state: state, version: version, summaryIsStale: false)

        let updatedSearch = MeetingSpeakerSearchInput(query: "Microphone", version: version, speakerRevision: state.revision)
        #expect(originalSearch != updatedSearch)
        await model.updateMatchingTurns(updatedSearch)

        #expect(model.matchingTurns.map(\.speaker) == [reassignedKey])
    }
}
