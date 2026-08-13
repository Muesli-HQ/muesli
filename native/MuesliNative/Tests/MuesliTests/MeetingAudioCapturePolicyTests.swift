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
