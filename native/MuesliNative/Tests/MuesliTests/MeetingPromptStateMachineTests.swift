import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingPromptStateMachine")
struct MeetingPromptStateMachineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(
        _ id: String = "googleMeet:meet.google.com/pwm-txwq-txy",
        suppressionID: String? = nil,
        evidence: Set<MeetingCandidate.Evidence> = [.micActive, .cameraActive, .browserURL, .foregroundApp]
    ) -> MeetingCandidate {
        MeetingCandidate(
            id: id,
            platform: .googleMeet,
            appName: "Chrome",
            url: "meet.google.com/pwm-txwq-txy",
            evidence: evidence,
            startedAt: now,
            meetingTitle: nil,
            suppressionID: suppressionID
        )
    }

    private func immediateMachine() -> MeetingPromptStateMachine {
        MeetingPromptStateMachine(candidateStabilityDelay: 0)
    }

    private func decision(
        _ machine: MeetingPromptStateMachine,
        candidate: MeetingCandidate?,
        visible: Bool = false,
        promptID: String? = nil,
        isRecording: Bool = false,
        isStartingRecording: Bool = false,
        isCalendarVisible: Bool = false,
        now: Date? = nil
    ) -> MeetingPromptDecision {
        machine.evaluate(
            candidate: candidate,
            detectionEnabled: true,
            isRecording: isRecording,
            isStartingRecording: isStartingRecording,
            isCalendarNotificationVisible: isCalendarVisible,
            visibility: MeetingPromptVisibility(isVisible: visible, currentPromptID: promptID, shownAt: nil),
            now: now ?? self.now
        )
    }

    @Test("eligible candidate waits for stability delay")
    func eligibleCandidateWaitsForStabilityDelay() {
        let machine = MeetingPromptStateMachine()
        let candidate = candidate(evidence: [.micActive, .cameraActive, .dedicatedApp])

        let first = decision(machine, candidate: candidate, now: now)
        let second = decision(machine, candidate: candidate, now: now.addingTimeInterval(2.9))
        let third = decision(machine, candidate: candidate, now: now.addingTimeInterval(3.1))

        #expect(first.action == .none)
        #expect(first.reason == .candidatePending)
        #expect(second.action == .none)
        #expect(second.reason == .candidatePending)
        #expect(third.action == .show)
        #expect(third.candidate?.id == candidate.id)
    }

    @Test("browser URL candidate waits for stability delay")
    func browserCandidateWaitsForStabilityDelay() {
        let machine = MeetingPromptStateMachine()
        let candidate = candidate()

        let first = decision(machine, candidate: candidate, now: now)
        let second = decision(machine, candidate: candidate, now: now.addingTimeInterval(3.1))

        #expect(first.reason == .candidatePending)
        #expect(second.action == .show)
        #expect(second.candidate?.id == candidate.id)
    }

    @Test("candidate change restarts stability delay")
    func candidateChangeRestartsStabilityDelay() {
        let machine = MeetingPromptStateMachine()
        let firstCandidate = candidate(evidence: [.micActive, .cameraActive, .dedicatedApp])
        let secondCandidate = candidate(
            "googleMeet:meet.google.com/abc-defg-hij",
            evidence: [.micActive, .cameraActive, .dedicatedApp]
        )

        #expect(decision(machine, candidate: firstCandidate, now: now).reason == .candidatePending)
        #expect(decision(machine, candidate: secondCandidate, now: now.addingTimeInterval(2)).reason == .candidatePending)

        let result = decision(machine, candidate: secondCandidate, now: now.addingTimeInterval(5.2))

        #expect(result.action == .show)
        #expect(result.candidate?.id == secondCandidate.id)
    }

    @Test("visible state clears after auto-dismiss and does not immediately re-show same candidate")
    func autoDismissClearsVisibleState() {
        let machine = immediateMachine()
        let candidate = candidate()

        machine.markShown(candidate)
        machine.markAutoDismissed(candidate, now: now)
        let result = decision(machine, candidate: candidate)

        #expect(machine.visiblePromptID == nil)
        #expect(result.action == .none)
        #expect(result.reason == .autoDismissedSuppression)
    }

    @Test("new candidate can show after prior candidate auto-dismiss")
    func newCandidateAfterAutoDismissShows() {
        let machine = immediateMachine()
        let oldCandidate = candidate()
        let newCandidate = candidate("googleMeet:meet.google.com/abc-defg-hij")

        machine.markShown(oldCandidate)
        machine.markAutoDismissed(oldCandidate, now: now)
        let result = decision(machine, candidate: newCandidate)

        #expect(result.action == .show)
        #expect(result.candidate?.id == newCandidate.id)
    }

    @Test("user dismiss suppresses only that candidate")
    func userDismissSuppressesOnlyThatCandidate() {
        let machine = immediateMachine()
        let dismissed = candidate()
        let other = candidate("googleMeet:meet.google.com/abc-defg-hij")

        machine.markShown(dismissed)
        machine.markUserDismissed(dismissed)

        #expect(decision(machine, candidate: dismissed).reason == .userDismissedSuppression)
        #expect(decision(machine, candidate: other).action == .show)
    }

    @Test("user dismiss suppresses same meeting session even if candidate id changes")
    func userDismissSuppressesSameMeetingSession() {
        let machine = immediateMachine()
        let dismissed = candidate("cal:evt-slack", suppressionID: "app:com.tinyspeck.slackmacgap:session:1")
        let sameSession = candidate(
            "app:com.tinyspeck.slackmacgap:session:1",
            suppressionID: "app:com.tinyspeck.slackmacgap:session:1"
        )

        machine.markShown(dismissed)
        machine.markUserDismissed(dismissed)

        let result = decision(machine, candidate: sameSession)

        #expect(result.action == .none)
        #expect(result.reason == .userDismissedSuppression)
    }

    @Test("user dismiss does not suppress a later meeting session")
    func userDismissDoesNotSuppressLaterMeetingSession() {
        let machine = immediateMachine()
        let dismissed = candidate("app:com.tinyspeck.slackmacgap:session:1")
        let laterSession = candidate("app:com.tinyspeck.slackmacgap:session:2")

        machine.markShown(dismissed)
        machine.markUserDismissed(dismissed)

        let result = decision(machine, candidate: laterSession)

        #expect(result.action == .show)
        #expect(result.candidate?.id == laterSession.id)
    }

    @Test("auto-dismiss suppression survives candidate dropout")
    func autoDismissSuppressionSurvivesCandidateDropout() {
        let machine = immediateMachine()
        let candidate = candidate()

        machine.markShown(candidate)
        machine.markAutoDismissed(candidate, now: now)

        #expect(decision(machine, candidate: nil, now: now.addingTimeInterval(1)).reason == .noCandidate)

        let result = decision(machine, candidate: candidate, now: now.addingTimeInterval(2))

        #expect(result.action == .none)
        #expect(result.reason == .autoDismissedSuppression)
    }

    @Test("browser auto-dismiss suppression expires for same candidate")
    func browserAutoDismissSuppressionExpires() {
        let machine = immediateMachine()
        let candidate = candidate()

        machine.markShown(candidate)
        machine.markAutoDismissed(candidate, now: now)

        let result = decision(machine, candidate: candidate, now: now.addingTimeInterval(121))

        #expect(result.action == .show)
    }

    @Test("app auto-dismiss suppression does not expire for same session")
    func appAutoDismissSuppressionDoesNotExpire() {
        let machine = immediateMachine()
        let candidate = candidate(
            "app:com.tinyspeck.slackmacgap:session:1",
            suppressionID: "app:com.tinyspeck.slackmacgap:session:1",
            evidence: [.micActive, .audioInputProcess, .dedicatedApp]
        )

        machine.markShown(candidate)
        machine.markAutoDismissed(candidate, now: now)

        let result = decision(machine, candidate: candidate, now: now.addingTimeInterval(3_600))

        #expect(result.action == .none)
        #expect(result.reason == .autoDismissedSuppression)
    }

    @Test("browser media session auto-dismiss suppression does not expire while session is stable")
    func browserMediaSessionAutoDismissSuppressionDoesNotExpire() {
        let machine = immediateMachine()
        let candidate = candidate(
            "meeting-session:browser:com.google.Chrome:1800000000",
            suppressionID: "meeting-session:browser:com.google.Chrome:1800000000",
            evidence: [.micActive, .audioInputProcess, .browserURL]
        )

        machine.markShown(candidate)
        machine.markAutoDismissed(candidate, now: now)

        let result = decision(machine, candidate: candidate, now: now.addingTimeInterval(3_600))

        #expect(result.action == .none)
        #expect(result.reason == .autoDismissedSuppression)
    }

    @Test("prompt does not show while recording or starting recording")
    func promptBlockedDuringRecordingStates() {
        let machine = immediateMachine()
        let candidate = candidate()

        #expect(decision(machine, candidate: candidate, isRecording: true).reason == .recording)
        #expect(decision(machine, candidate: candidate, isStartingRecording: true).reason == .recording)
    }

    @Test("recording state resets pending candidate dwell")
    func recordingStateResetsPendingCandidateDwell() {
        let machine = MeetingPromptStateMachine()
        let candidate = candidate(evidence: [.micActive, .cameraActive, .dedicatedApp])

        #expect(decision(machine, candidate: candidate, now: now).reason == .candidatePending)
        #expect(decision(machine, candidate: candidate, isRecording: true, now: now.addingTimeInterval(2)).reason == .recording)

        let afterRecording = decision(machine, candidate: candidate, now: now.addingTimeInterval(4))
        let afterFreshDwell = decision(machine, candidate: candidate, now: now.addingTimeInterval(7.1))

        #expect(afterRecording.reason == .candidatePending)
        #expect(afterFreshDwell.action == .show)
    }

    @Test("calendar notification blocks detection notification without overwriting it")
    func calendarNotificationBlocksDetectionNotification() {
        let machine = immediateMachine()
        let candidate = candidate()

        let result = decision(machine, candidate: candidate, isCalendarVisible: true)

        #expect(result.action == .none)
        #expect(result.reason == .calendarNotificationVisible)
    }
}
