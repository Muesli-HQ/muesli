import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting speaker Accessibility evidence")
struct MeetingSpeakerAccessibilityTests {
    @Test func syntheticSourceContractsNeedIndependentSpeakingStatus() {
        for kind in MeetingSpeakerApp.allCases {
            let tile = MeetingSpeakerAXNode(id: "tile", role: "AXGroup", detail: kind.tileMarker,
                children: [.init(id: "name", role: "AXStaticText", detail: "participant name", value: "Example 🌿"),
                           .init(id: "activity", role: "AXImage", detail: "speaking status", value: "true")])
            let window = MeetingSpeakerAXWindow(scope: "pid/window/layout", app: kind,
                documentURL: kind == .meet ? "https://meet.google.com/abc-defg-hij" : nil, root: tile)
            let frame = MeetingSpeakerSources.decode(window)
            #expect(frame.participants.count == 1)
            #expect(frame.active?.name == "Example 🌿")
            var roster = window
            roster.root.children.removeAll { $0.id == "activity" }
            #expect(MeetingSpeakerSources.decode(roster).reason == .rosterOnly)
            roster.truncated = true
            #expect(MeetingSpeakerSources.decode(roster).reason == .truncated)
        }
    }

    @Test func multipleWindowsHostsAndUnrelatedBrowserWithhold() {
        let a = frame(scope: "window-a", app: .zoom), b = frame(scope: "window-b", app: .teams)
        #expect(MeetingSpeakerSources.combine([a, b]).reason == .multipleHosts)
        #expect(MeetingSpeakerSources.combine([a, frame(scope: "window-c", app: .zoom)]).reason == .multipleWindows)
        let unrelated = MeetingSpeakerAXWindow(scope: "browser", app: .meet, documentURL: "https://example.test", root: .init(id: "x", role: "AXGroup", detail: "video tile"))
        #expect(MeetingSpeakerSources.decode(unrelated).active == nil)
    }

    @Test func unrecognizedConfirmedMeetWindowWithholdsAnotherAppsSpeaker() {
        let zoom = frame(scope: "zoom", app: .zoom)
        let changedMeetLayout = MeetingSpeakerAXWindow(
            scope: "browser/meet",
            app: .meet,
            documentURL: "https://meet.google.com/abc-defg-hij",
            root: .init(id: "root", role: "AXWindow", detail: "changed layout")
        )
        let meetFrame = MeetingSpeakerSources.decode(changedMeetLayout)

        #expect(meetFrame.reason == .ambiguous)
        #expect(MeetingSpeakerSources.combine([zoom, meetFrame]).active == nil)
    }

    @Test func votesUseRealSpeechAndDistinctPolls() {
        var state = fixture()
        let key = state.speakers[0].key
        let observations = (0...3).map { MeetingSpeakerObservation(time: Double($0), continuity: "one", frame: frame()) }
        let timeline = MeetingSpeakerTimeline(observations: observations)
        let activity = [MeetingSpeakerActivity(key: key, start: 0, end: 3)]
        #expect(timeline.assignments(activities: activity).names[key]?.name == "Example")
        timeline.apply(activities: activity, to: &state)
        #expect(state.labels[key] == "Example")
        #expect(state.turns[0].text == "Words")
        let assignedManualName = state.assign(.init(name: "Manual", provenance: .manual), to: key)
        #expect(assignedManualName == true)
        timeline.apply(activities: activity, to: &state)
        #expect(state.labels[key] == "Manual")
        let reset = MeetingSpeakerTimeline(observations: [observations[0], observations[1], observations[0], observations[2], observations[3]])
        #expect(reset.assignments(activities: activity).names[key]?.name == "Example")
        state.declineAutomaticName(for: key)
        #expect(state.labels[key] == "Manual")
        let gap = MeetingSpeakerTimeline(observations: [observations[0], .init(time: 3, continuity: "two", frame: frame())])
        #expect(gap.assignments(activities: activity).names.isEmpty)
        #expect(MeetingSpeakerTimeline(observations: observations, incomplete: true).assignments(activities: activity).names.isEmpty)
    }

    @Test func votesAcceptPollIntervalsWithinSharedSamplingBudget() {
        let state = fixture()
        let key = state.speakers[0].key
        let observations = [0.0, 1.5, 3.0, 4.5].map {
            MeetingSpeakerObservation(time: $0, continuity: "one", frame: frame())
        }
        let timeline = MeetingSpeakerTimeline(observations: observations)

        #expect(timeline.assignments(activities: [.init(key: key, start: 0, end: 4.5)]).names[key]?.name == "Example")
        #expect(MeetingSpeakerAccessibilitySamplingPolicy.maximumVoteGap
            >= MeetingSpeakerAccessibilitySamplingPolicy.pollInterval
                + MeetingSpeakerAccessibilitySamplingPolicy.maximumReadDuration)
    }

    @Test func equalClockPollOnlySkipsThatPair() {
        let state = fixture()
        let key = state.speakers[0].key
        let times = [0.0, 1.0, 1.0, 2.0, 3.0, 4.0]
        let observations = times.map { MeetingSpeakerObservation(time: $0, continuity: "one", frame: frame()) }
        let timeline = MeetingSpeakerTimeline(observations: observations)

        #expect(timeline.assignments(activities: [.init(key: key, start: 0, end: 4)]).names[key]?.name == "Example")
    }

    @Test func clockResetDoesNotDoubleCountOverlappingSpeechIntervals() {
        let state = fixture()
        let key = state.speakers[0].key
        let times = [0.0, 1.0, 0.0, 1.0, 2.0]
        let observations = times.map { MeetingSpeakerObservation(time: $0, continuity: "one", frame: frame()) }
        let timeline = MeetingSpeakerTimeline(observations: observations)

        #expect(timeline.assignments(activities: [.init(key: key, start: 0, end: 1.5)]).names[key] == nil)
    }

    @Test func meetDocumentSelectionFiltersUnrelatedWindowsBeforeRelevantLimit() {
        let meet = "https://meet.google.com/abc-defg-hij"
        let selected = MeetingSpeakerSources.meetDocumentURLs(
            ["https://example.test/1", nil, "https://calendar.google.com", meet],
            maximumRelevantWindows: 1
        )

        #expect(selected == [meet])
        #expect(MeetingSpeakerSources.meetDocumentURLs([meet, "https://meet.google.com/klm-nopq-rst"], maximumRelevantWindows: 1) == nil)

        let zoom = frame(scope: "zoom", app: .zoom)
        let overflow = MeetingSpeakerFrame(scope: "browser", app: .meet, reason: .windowLimit)
        let combinedOverflow = MeetingSpeakerSources.combine([zoom, overflow])
        #expect(combinedOverflow.active == nil)
        #expect(combinedOverflow.reason == .windowLimit)
        #expect(combinedOverflow.diagnosticReasons == [.windowLimit])
        let overflowOnly = MeetingSpeakerSources.combine([overflow])
        #expect(overflowOnly.reason == .windowLimit)
        #expect(overflowOnly.diagnosticReasons == [.windowLimit])
    }

    @Test func incompleteMeetScanWithholdsNamesFromAnotherHost() {
        let combined = MeetingSpeakerSources.combine([
            frame(scope: "zoom", app: .zoom),
            MeetingSpeakerSources.incompleteMeetScan()
        ])

        #expect(combined.active == nil)
        #expect(combined.reason == .truncated)
    }

    @Test func overlappingClustersAndOneParticipantForTwoClustersWithhold() {
        let state = fixture(), key = state.speakers[0].key
        let other = MeetingSpeakerKey(epoch: state.epoch, channel: .system, clusterID: "other")
        let timeline = MeetingSpeakerTimeline(observations: (0...7).map { .init(time: Double($0), continuity: "one", frame: frame()) })
        #expect(timeline.assignments(activities: [.init(key: key, start: 0, end: 4), .init(key: other, start: 3, end: 7)]).names.isEmpty)
        #expect(timeline.assignments(activities: [.init(key: key, start: 0, end: 3), .init(key: other, start: 4, end: 7)]).names.isEmpty)
    }

    @Test func duplicateDisplayNamesFromDifferentParticipantsWithholdAssignments() {
        let state = fixture()
        let first = state.speakers[0].key
        let second = MeetingSpeakerKey(epoch: state.epoch, channel: .system, clusterID: "second")
        let observations = (0...7).map { index in
            let participantID = index <= 3 ? "window/first" : "window/second"
            return MeetingSpeakerObservation(time: Double(index), continuity: "one",
                frame: .init(scope: "window", app: .zoom,
                    participants: [.init(id: participantID, name: "Example")], activeID: participantID))
        }
        let timeline = MeetingSpeakerTimeline(observations: observations)

        #expect(timeline.assignments(activities: [
            .init(key: first, start: 0, end: 3), .init(key: second, start: 4, end: 7)
        ]).names.isEmpty)
    }

    @Test func sampleClockAndExperimentalDefault() throws {
        var tracker = MeetingChunkTimingTracker()
        #expect(tracker.elapsedTimeSeconds == nil)
        tracker.start(); tracker.append(sampleCount: 32_000)
        #expect(tracker.elapsedTimeSeconds == 2)
        _ = tracker.rotate(); tracker.append(sampleCount: 16_000)
        #expect(tracker.elapsedTimeSeconds == 3)
        _ = tracker.finish(); #expect(tracker.elapsedTimeSeconds == nil)
        #expect(!AppConfig().enableMeetingSpeakerAccessibility)
        var config = AppConfig(); config.enableMeetingSpeakerAccessibility = true
        let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.enableMeetingSpeakerAccessibility)
        var state = fixture()
        let key = state.speakers[0].key
        state.assign(.init(name: "Example", provenance: .accessibility), to: key)
        state.removeAccessibilityAssignments()
        #expect(state.labels[key] == "Speaker 1")
        #expect(state.speakers[0].history.isEmpty)
    }

    @Test func sessionResultAuthorizationRevocationPreservesNotesWhenNoAccessibilityNamesWereApplied() {
        let state = fixture()
        let result = sessionResult(
            state: state,
            authorization: UUID(),
            title: "Generated title",
            notes: "Notes from the unnamed transcript"
        )

        let validated = result.validatingAccessibilityAuthorization(nil)

        #expect(validated.title == "Generated title")
        #expect(validated.formattedNotes == "Notes from the unnamed transcript")
        #expect(validated.rawTranscript == result.rawTranscript)
        #expect(validated.summaryIsCurrent == true)
        #expect(validated.speakerAccessibilityAuthorization == nil)
    }

    @Test func sessionResultAuthorizationRevocationScrubsAccessibilityNames() {
        var state = fixture()
        let key = state.speakers[0].key
        let assignedAccessibilityName = state.assign(.init(name: "Example", provenance: .accessibility), to: key)
        #expect(assignedAccessibilityName)
        let result = sessionResult(
            state: state,
            authorization: UUID(),
            title: "Example planning",
            notes: "Example will send the outline"
        )
        var fallbackState = state
        fallbackState.removeAccessibilityAssignments()

        let validated = result.validatingAccessibilityAuthorization(nil)

        #expect(validated.rawTranscript == fallbackState.render())
        #expect(validated.title == result.originalTitle)
        #expect(validated.formattedNotes == "Speaker evidence changed. Update notes from the saved transcript.")
        #expect(validated.summaryIsCurrent == false)
        #expect(validated.speakerState?.labels[key] == "Speaker 1")
    }

    @Test func resumeOverrideRetainsAccessibilityRevocationFallback() {
        var state = fixture()
        let key = state.speakers[0].key
        let assignedAccessibilityName = state.assign(.init(name: "Example", provenance: .accessibility), to: key)
        #expect(assignedAccessibilityName)
        let result = sessionResult(
            state: state,
            authorization: UUID(),
            title: "Example planning",
            notes: "Example will send the outline"
        )
        let prior = "[00:00:00] Speaker 2: Earlier words"
        let combined = MeetingResumePolicy.combinedResumeTranscript(prior: prior, new: result.rawTranscript)
        var fallbackState = state
        fallbackState.removeAccessibilityAssignments()
        let expectedFallback = MeetingResumePolicy.combinedResumeTranscript(prior: prior, new: fallbackState.render())

        let resumed = result.overriding(rawTranscript: combined, formattedNotes: "Example attended and will send the outline")
        let validated = resumed.validatingAccessibilityAuthorization(nil)

        #expect(validated.rawTranscript == expectedFallback)
        #expect(validated.rawTranscript.contains("Earlier words"))
        #expect(validated.title == result.originalTitle)
        #expect(validated.formattedNotes == "Speaker evidence changed. Update notes from the saved transcript.")
        #expect(validated.summaryIsCurrent == false)
    }

    private func frame(scope: String = "window", app: MeetingSpeakerApp = .zoom) -> MeetingSpeakerFrame {
        .init(scope: scope, app: app, participants: [.init(id: "\(scope)/tile", name: "Example")], activeID: "\(scope)/tile")
    }

    private func sessionResult(
        state: MeetingSpeakerState,
        authorization: UUID,
        title: String,
        notes: String
    ) -> MeetingSessionResult {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return MeetingSessionResult(
            title: title,
            originalTitle: "Meeting title",
            calendarEventID: nil,
            startTime: start,
            endTime: start.addingTimeInterval(3),
            durationSeconds: 3,
            rawTranscript: state.render(),
            formattedNotes: notes,
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot,
            speakerState: state,
            speakerAccessibilityAuthorization: authorization
        )
    }

    private func fixture() -> MeetingSpeakerState {
        let epoch = UUID(), keyID = "cluster"
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: keyID)
        return .init(epoch: epoch, speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1")], turns: [.init(speaker: key, timestamp: "00:00:00", start: 0, end: 3, text: "Words")])
    }
}
