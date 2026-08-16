import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting audio capture policy")
struct MeetingAudioCapturePolicyTests {
    @Test("idle meeting is not capturing")
    func idleIsNotCapturing() {
        #expect(
            MeetingAudioCapturePolicy.isCapturingAudio(
                isStarting: false,
                hasPreparingSession: false,
                isRecording: false,
                isStopping: false
            ) == false
        )
    }

    @Test("blocks dictation while a meeting is preparing")
    func preparingIsCapturing() {
        #expect(
            MeetingAudioCapturePolicy.isCapturingAudio(
                isStarting: true,
                hasPreparingSession: false,
                isRecording: false,
                isStopping: false
            )
        )
        #expect(
            MeetingAudioCapturePolicy.isCapturingAudio(
                isStarting: false,
                hasPreparingSession: true,
                isRecording: false,
                isStopping: false
            )
        )
    }

    @Test("active and paused recordings are capturing")
    func recordingIsCapturing() {
        #expect(
            MeetingAudioCapturePolicy.isCapturingAudio(
                isStarting: false,
                hasPreparingSession: false,
                isRecording: true,
                isStopping: false
            )
        )
    }

    @Test("stopping still counts as capturing")
    func stoppingIsCapturing() {
        #expect(
            MeetingAudioCapturePolicy.isCapturingAudio(
                isStarting: false,
                hasPreparingSession: false,
                isRecording: false,
                isStopping: true
            )
        )
    }

    @Test("background processing alone does not count as capturing")
    func backgroundProcessingIsNotCapturing() {
        #expect(
            MeetingAudioCapturePolicy.isCapturingAudio(
                isStarting: false,
                hasPreparingSession: false,
                isRecording: false,
                isStopping: false
            ) == false
        )
        #expect(
            MeetingAudioCapturePolicy.shouldSuppressMeetingMonitor(
                isCapturingAudio: false,
                isDictationActivityInProgress: false,
                backgroundMeetingProcessingCount: 1
            )
        )
        #expect(
            MeetingAudioCapturePolicy.shouldSuppressMeetingMonitor(
                isCapturingAudio: false,
                isDictationActivityInProgress: false,
                backgroundMeetingProcessingCount: 0
            ) == false
        )
    }

    @Test("suppresses the monitor during dictation or capture")
    func suppressesForForegroundActivity() {
        #expect(
            MeetingAudioCapturePolicy.shouldSuppressMeetingMonitor(
                isCapturingAudio: true,
                isDictationActivityInProgress: false,
                backgroundMeetingProcessingCount: 0
            )
        )
        #expect(
            MeetingAudioCapturePolicy.shouldSuppressMeetingMonitor(
                isCapturingAudio: false,
                isDictationActivityInProgress: true,
                backgroundMeetingProcessingCount: 0
            )
        )
    }
}

@Suite("Dictation transcription foreground policy")
struct DictationTranscriptionForegroundPolicyTests {
    @Test("completed dictation may update foreground when no newer capture owns it")
    func completedDictationMayUpdateForeground() {
        #expect(DictationTranscriptionForegroundPolicy.shouldApplyResult(
            isMeetingCapturingAudio: false,
            hasActiveRecording: false,
            hasPendingStop: false,
            isStreaming: false,
            isPresentationStateEligible: true
        ))
    }

    @Test("meeting capture blocks stale dictation foreground updates")
    func meetingCaptureBlocksForegroundUpdate() {
        #expect(!DictationTranscriptionForegroundPolicy.shouldApplyResult(
            isMeetingCapturingAudio: true,
            hasActiveRecording: false,
            hasPendingStop: false,
            isStreaming: false,
            isPresentationStateEligible: true
        ))
    }

    @Test("newer dictation activity blocks stale foreground updates")
    func newerDictationActivityBlocksForegroundUpdate() {
        #expect(!DictationTranscriptionForegroundPolicy.shouldApplyResult(
            isMeetingCapturingAudio: false,
            hasActiveRecording: true,
            hasPendingStop: false,
            isStreaming: false,
            isPresentationStateEligible: true
        ))
        #expect(!DictationTranscriptionForegroundPolicy.shouldApplyResult(
            isMeetingCapturingAudio: false,
            hasActiveRecording: false,
            hasPendingStop: true,
            isStreaming: false,
            isPresentationStateEligible: true
        ))
        #expect(!DictationTranscriptionForegroundPolicy.shouldApplyResult(
            isMeetingCapturingAudio: false,
            hasActiveRecording: false,
            hasPendingStop: false,
            isStreaming: true,
            isPresentationStateEligible: true
        ))
    }

    @Test("suppressed completion retires only an otherwise finished transcription")
    func suppressedCompletionRetiresFinishedTranscription() {
        #expect(DictationTranscriptionForegroundPolicy.shouldRetireSuppressedResult(
            isTranscribing: true,
            hasActiveRecording: false,
            hasPendingStop: false,
            isStreaming: false
        ))
        #expect(!DictationTranscriptionForegroundPolicy.shouldRetireSuppressedResult(
            isTranscribing: true,
            hasActiveRecording: true,
            hasPendingStop: false,
            isStreaming: false
        ))
        #expect(!DictationTranscriptionForegroundPolicy.shouldRetireSuppressedResult(
            isTranscribing: false,
            hasActiveRecording: false,
            hasPendingStop: false,
            isStreaming: false
        ))
    }
}

@Suite("Dictation audio session failure policy")
struct DictationAudioSessionFailurePolicyTests {
    @Test("handles the controller-owned active session after the manager clears its hint")
    func handlesActiveSessionFailure() {
        let activeSessionID = UUID()
        #expect(DictationAudioSessionFailurePolicy.shouldHandleFailure(
            failedSessionID: activeSessionID,
            activeSessionID: activeSessionID,
            pendingStopSessionID: nil
        ))
    }

    @Test("rejects a stale session failure")
    func rejectsStaleSessionFailure() {
        #expect(!DictationAudioSessionFailurePolicy.shouldHandleFailure(
            failedSessionID: UUID(),
            activeSessionID: UUID(),
            pendingStopSessionID: nil
        ))
    }
}
