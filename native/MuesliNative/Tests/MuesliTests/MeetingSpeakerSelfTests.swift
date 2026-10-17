import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting self evidence")
struct MeetingSpeakerSelfTests {
    @Test func uniqueVoiceAndConflicts() {
        var state = fixture(), other = fixture()
        let a = state.speakers[0].key, b = state.speakers[1].key, profile = UUID()
        state.applySelfEvidence(accessibility: [], voice: [a], ownerName: "Example 🌿", profileID: profile)
        #expect(state.labels[a] == "Example 🌿 (You)")
        #expect(state.speakers.filter(\.isSelf).count == 1)
        other.applySelfEvidence(accessibility: [b], voice: [a], ownerName: "Example", profileID: profile)
        #expect(other.speakers.filter(\.isSelf).isEmpty)
        other.applySelfEvidence(accessibility: [a], voice: [], ownerName: "Example", profileID: nil)
        #expect(other.speakers.filter(\.isSelf).isEmpty) // endpoint self cannot identify a shared-mic human
        other.applySelfEvidence(accessibility: [], voice: [a, b], ownerName: "Example", profileID: profile)
        #expect(other.speakers.filter(\.isSelf).isEmpty)
    }
    @Test func bareSelfCanBeDeclinedAndRevokedWithoutLosingManualName() {
        var state = fixture()
        let a = state.speakers[0].key, b = state.speakers[1].key
        state.applySelfEvidence(accessibility: [], voice: [a], ownerName: "", profileID: UUID())
        #expect(state.labels[a] == "You")
        let declinedName = state.correct(.declineName(a))
        #expect(declinedName)
        #expect(!state.speakers[0].isSelf)
        state.applySelfEvidence(accessibility: [], voice: [a], ownerName: "", profileID: UUID())
        #expect(!state.speakers[0].isSelf)
        let undidDecline = state.correct(.undo)
        #expect(undidDecline)
        let renamed = state.correct(.rename(b, "Manual"))
        #expect(renamed)
        let merged = state.correct(.merge(a, into: b))
        #expect(merged)
        state.removeSelfEvidence()
        #expect(state.labels[b] == "Manual")
        #expect(state.speakers.filter(\.isSelf).isEmpty)
        _ = state.correct(.undo)
        #expect(state.speakers.filter(\.isSelf).isEmpty)
    }
    @Test func separateClockAndDefaultOff() throws {
        #expect(!AppConfig().enableMeetingOwnerRecognition)
        let state = fixture(), key = state.speakers[0].key
        let person = MeetingSpeakerParticipant(id: "window/tile", name: "Example", isSelf: true)
        let frame = MeetingSpeakerFrame(scope: "window", app: .zoom, participants: [person], activeID: person.id)
        let timeline = MeetingSpeakerTimeline(observations: (0...3).map { .init(time: Double($0) + 50, continuity: "one", frame: frame, microphoneTime: Double($0)) })
        #expect(timeline.assignments(activities: [.init(key: key, start: 0, end: 3)], channel: .microphone).explicitSelf == [key])
    }
    @Test func resumeKeepsRevocationAndUntouchedPriorText() {
        let state = fixture(), token = UUID()
        var named = state
        named.applySelfEvidence(accessibility: [], voice: [state.speakers[0].key], ownerName: "Example", profileID: UUID())
        var result = MeetingSessionResult(title: "Generated", originalTitle: "Manual", calendarEventID: nil,
            startTime: Date(), endTime: Date(), durationSeconds: 3, rawTranscript: named.render(), formattedNotes: "Generated notes",
            retainedRecordingURL: nil, retainedRecordingError: nil, systemRecordingURL: nil, templateSnapshot: MeetingTemplates.auto.snapshot,
            speakerState: named, speakerAuthorizationFallbackTranscript: state.render(), ownerRecognitionAuthorization: token)
        let prior = "Prior manual words: unchanged"
        let fallback = MeetingResumePolicy.combinedResumeTranscript(prior: prior, new: state.render())
        result = result.overriding(rawTranscript: MeetingResumePolicy.combinedResumeTranscript(prior: prior, new: named.render()),
            formattedNotes: "Merged notes", fallbackTranscript: fallback)
        #expect(result.ownerRecognitionAuthorization == token)
        let revoked = result.validatingOwnerAuthorization(nil)
        #expect(revoked.rawTranscript == fallback)
        #expect(revoked.rawTranscript.hasPrefix(prior))
        #expect(revoked.title == "Manual")
        #expect(revoked.summaryIsCurrent == false)
    }
    @Test func ownerAuthorizationRevocationKeepsGeneratedTextWhenNoSelfEvidenceWasApplied() {
        let state = fixture()
        let result = MeetingSessionResult(title: "Generated", originalTitle: "Manual", calendarEventID: nil,
            startTime: Date(), endTime: Date(), durationSeconds: 3, rawTranscript: state.render(), formattedNotes: "Generated notes",
            retainedRecordingURL: nil, retainedRecordingError: nil, systemRecordingURL: nil, templateSnapshot: MeetingTemplates.auto.snapshot,
            speakerState: state, speakerAuthorizationFallbackTranscript: state.render(), ownerRecognitionAuthorization: UUID())

        let revoked = result.validatingOwnerAuthorization(nil)

        #expect(revoked.rawTranscript == result.rawTranscript)
        #expect(revoked.title == result.title)
        #expect(revoked.formattedNotes == result.formattedNotes)
        #expect(revoked.summaryIsCurrent == true)
        #expect(revoked.ownerRecognitionAuthorization == nil)
    }

    @Test func newlyGrantedAuthorizationsDoNotInvalidateEvidenceThatWasNotCaptured() {
        let captured = UUID()
        #expect(MeetingSpeakerAuthorizationSnapshot.matches(
            capturedAccessibility: nil,
            currentAccessibility: UUID(),
            capturedOwnerRecognition: nil,
            currentOwnerRecognition: UUID()
        ))
        #expect(MeetingSpeakerAuthorizationSnapshot.matches(
            capturedAccessibility: captured,
            currentAccessibility: captured,
            capturedOwnerRecognition: captured,
            currentOwnerRecognition: captured
        ))
        #expect(!MeetingSpeakerAuthorizationSnapshot.matches(
            capturedAccessibility: captured,
            currentAccessibility: nil,
            capturedOwnerRecognition: nil,
            currentOwnerRecognition: nil
        ))
        #expect(!MeetingSpeakerAuthorizationSnapshot.matches(
            capturedAccessibility: nil,
            currentAccessibility: nil,
            capturedOwnerRecognition: captured,
            currentOwnerRecognition: UUID()
        ))
    }

    @Test func resumeSummaryOverrideTracksCombinedSummaryOutcome() {
        let result = MeetingSessionResult(title: "Generated", originalTitle: "Manual", calendarEventID: nil,
            startTime: Date(), endTime: Date(), durationSeconds: 3, rawTranscript: "New speech", formattedNotes: "Session notes",
            retainedRecordingURL: nil, retainedRecordingError: nil, systemRecordingURL: nil, templateSnapshot: MeetingTemplates.auto.snapshot,
            summaryIsCurrent: false)

        let regenerated = result.overriding(rawTranscript: "Prior and new speech", formattedNotes: "Combined notes", summaryIsCurrent: true)
        let failed = result.overriding(rawTranscript: "Prior and new speech", formattedNotes: "Failure notes", summaryIsCurrent: false)

        #expect(regenerated.summaryIsCurrent == true)
        #expect(failed.summaryIsCurrent == false)
    }
    @Test @MainActor func liveTranscriptKeepsSpeakerIdentityAfterResumePrefix() {
        let epoch = UUID()
        let first = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "first")
        let second = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "second")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: first, rank: 1, fallbackLabel: "Local speaker 1"),
                       .init(key: second, rank: 2, fallbackLabel: "Local speaker 2")],
            turns: [.init(speaker: first, timestamp: "10:30:00", start: 0, end: 2, text: "First live words"),
                    .init(speaker: second, timestamp: "10:30:03", start: 3, end: 5, text: "Second live words")])
        let prefix = "[10:00:00] Prior speaker: Prior words"
        let transcript = MeetingResumePolicy.combinedResumeTranscript(prior: prefix, new: state.render())
        let model = LiveTranscriptPresentationModel()

        model.update(transcript: transcript, partialYou: "", partialOthers: "", speakerState: state,
                     microphoneLabel: "Microphone", transcriptPrefix: prefix)

        #expect(model.messages.map(\.text) == ["Prior words", "— Resumed —", "First live words", "Second live words"])
        #expect(model.messages.suffix(2).map(\.speakerKey) == [first, second])
    }
    @Test @MainActor func provisionalMicrophoneIsNeutral() {
        let model = LiveTranscriptPresentationModel()
        model.update(transcript: "", partialYou: "words", partialOthers: "", microphoneLabel: "Microphone")
        #expect(model.microphoneLabel == "Microphone")
        #expect(LiveTranscriptCopyContent.text(transcript: "", partialYou: "words", partialOthers: "", microphoneLabel: "Microphone") == "Microphone: words")
    }
    private func fixture() -> MeetingSpeakerState {
        let epoch = UUID()
        let a = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "a")
        let b = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "b")
        return .init(epoch: epoch, speakers: [.init(key: a, rank: 1, fallbackLabel: "Local speaker 1"), .init(key: b, rank: 2, fallbackLabel: "Local speaker 2")],
            turns: [.init(speaker: a, timestamp: "00:00:00", start: 0, end: 3, text: "Words")])
    }
}
