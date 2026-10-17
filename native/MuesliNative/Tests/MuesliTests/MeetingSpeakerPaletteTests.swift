import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting speaker palette")
struct MeetingSpeakerPaletteTests {
    @Test func deterministicTokensAndFixedSelf() throws {
        let epoch = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "cluster")
        #expect(MeetingSpeakerPalette.colour(for: key, isSelf: false, isPerson: true) == MeetingSpeakerPalette.remote[1])
        for index in 0..<256 {
            let other = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "cluster\(index)")
            let decoded = try JSONDecoder().decode(MeetingSpeakerKey.self, from: JSONEncoder().encode(other))
            #expect(MeetingSpeakerPalette.colour(for: other, isSelf: false, isPerson: true) == MeetingSpeakerPalette.colour(for: decoded, isSelf: false, isPerson: true))
            #expect(MeetingSpeakerPalette.colour(for: other, isSelf: true, isPerson: true) == MeetingSpeakerPalette.owner)
            #expect(MeetingSpeakerPalette.colour(for: other, isSelf: false, isPerson: false) == MeetingSpeakerPalette.neutral)
        }
        #expect(MeetingSpeakerPalette.colour(for: nil, isSelf: false, isPerson: true) == MeetingSpeakerPalette.neutral)
    }

    @Test func foregroundsHaveReadableContrastOnRealBubbleSurfaces() {
        for colour in MeetingSpeakerPalette.remote + [MeetingSpeakerPalette.owner, MeetingSpeakerPalette.neutral] {
            for surface in [MuesliTheme.backgroundBaseLightHex, MuesliTheme.surfacePrimaryLightHex] {
                #expect(contrast(colour.light, surface) >= 4.5)
            }
            for surface in [MuesliTheme.backgroundBaseDarkHex, MuesliTheme.surfacePrimaryDarkHex] {
                #expect(contrast(colour.dark, surface) >= 4.5)
            }
        }
    }

    @Test func mergedSelfUsesSurvivorPaletteColourInStructuredMessages() {
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
        let targetColour = MeetingSpeakerPalette.colour(for: remote.key, isSelf: false, isPerson: true)
        let mergedSelf = state.correct(.merge(you.key, into: remote.key))
        #expect(mergedSelf)

        let messages = TranscriptChatMessage.messages(from: state.render(), speakerState: state)

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.isUser && $0.speakerPaletteIsSelf == false })
        #expect(messages.allSatisfy {
            MeetingSpeakerPalette.colour(
                for: $0.speakerKey,
                isSelf: $0.speakerPaletteIsSelf ?? $0.isUser,
                isPerson: $0.speakerIsPerson ?? false
            ) == targetColour
        })
    }

    private func contrast(_ a: Int, _ b: Int) -> Double {
        func luminance(_ rgb: Int) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let c = Double((rgb >> shift) & 255) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

extension MeetingSpeakerPaletteTests {
    @Test @MainActor func structuredLiveUpdatesPreserveKeysAndAggregateRoles() {
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "a")
        var state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
            turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "First")])
        let model = LiveTranscriptPresentationModel()
        model.update(transcript: state.render(), partialYou: "", partialOthers: "", speakerState: state)
        #expect(model.messages.first?.speakerKey == key)
        #expect(model.messages.first?.speakerIsPerson == true)
        state.speakers[0].isAssignable = false
        model.update(transcript: state.render(), partialYou: "", partialOthers: "", speakerState: state)
        #expect(model.messages.first?.speakerIsPerson == false)
        state.turns.append(.init(speaker: key, timestamp: "00:00:03", start: 3, end: 4, text: "Second"))
        model.update(transcript: state.render(), partialYou: "", partialOthers: "", speakerState: state)
        #expect(model.messages.map(\.speakerKey) == [key, key])
        #expect(model.messages.map(\.id) == [0, 1])
        model.update(transcript: "Edited plain text", partialYou: "", partialOthers: "", speakerState: state)
        #expect(model.messages.first?.speakerKey == nil)
        model.reset()
        #expect(model.messages.isEmpty)
    }
}

extension MeetingSpeakerPaletteTests {
    @Test @MainActor func stateAwareLiveAndFloatingModelsPreserveColourWhenStructuredStateIsSupplied() {
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "cluster")
        var state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")],
            turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Words")])
        let original = MeetingSpeakerPalette.colour(for: key, isSelf: false, isPerson: true)
        let assigned = state.assign(.init(name: "Example", provenance: .manual), to: key)
        #expect(assigned)
        let live = LiveTranscriptPresentationModel(), floating = FloatingMeetingTranscriptModel()
        live.update(transcript: state.render(), partialYou: "", partialOthers: "", speakerState: state)
        floating.update(transcript: state.render(), partialYou: "", partialOthers: "", speakerState: state)
        for message in live.messages + floating.presentation.messages {
            #expect(message.speaker == "Example")
            #expect(MeetingSpeakerPalette.colour(for: message.speakerKey, isSelf: message.isUser,
                isPerson: message.speakerIsPerson ?? false) == original)
        }
    }

    @Test @MainActor func floatingTranscriptKeepsResumedPrefixForDisplayAndCopy() {
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "local")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: key, rank: 1, fallbackLabel: "You", isSelf: true)],
            turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Current speech")])
        let prefix = "[10:00:00] You: Earlier speech"
        let resumedPrior = MeetingResumePolicy.transcriptForResume(prefix, speakerState: nil)
        let resumedTranscript = MeetingResumePolicy.combinedResumeTranscript(
            prior: resumedPrior.text, new: state.render())
        let floating = FloatingMeetingTranscriptModel()

        floating.update(transcript: resumedTranscript, partialYou: "", partialOthers: "",
            speakerState: state, transcriptPrefix: resumedPrior.text)

        #expect(resumedPrior.text == prefix)
        #expect(floating.presentation.messages.contains { $0.text == "Earlier speech" })
        #expect(floating.presentation.messages.contains { $0.text == "Current speech" })
        #expect(floating.presentation.transcriptForCopy == resumedTranscript)
    }
}
