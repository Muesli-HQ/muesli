import Foundation

enum MeetingAudioCapturePolicy {
    /// True while meeting audio hardware may still be contended.
    /// Background transcription after stop is not capture.
    static func isCapturingAudio(
        isStarting: Bool,
        hasPreparingSession: Bool,
        isRecording: Bool,
        isStopping: Bool
    ) -> Bool {
        isStarting || hasPreparingSession || isRecording || isStopping
    }

    static func shouldSuppressMeetingMonitor(
        isCapturingAudio: Bool,
        isDictationActivityInProgress: Bool,
        backgroundMeetingProcessingCount: Int
    ) -> Bool {
        isCapturingAudio
            || isDictationActivityInProgress
            || backgroundMeetingProcessingCount > 0
    }
}
