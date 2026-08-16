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

enum DictationTranscriptionForegroundPolicy {
    static func shouldApplyResult(
        isMeetingCapturingAudio: Bool,
        hasActiveRecording: Bool,
        hasPendingStop: Bool,
        isStreaming: Bool,
        isPresentationStateEligible: Bool
    ) -> Bool {
        !isMeetingCapturingAudio
            && !hasActiveRecording
            && !hasPendingStop
            && !isStreaming
            && isPresentationStateEligible
    }

    static func shouldRetireSuppressedResult(
        ownsLifecycle: Bool,
        isTranscribing: Bool,
        hasActiveRecording: Bool,
        hasPendingStop: Bool,
        isStreaming: Bool
    ) -> Bool {
        ownsLifecycle
            && isTranscribing
            && !hasActiveRecording
            && !hasPendingStop
            && !isStreaming
    }
}

enum DictationAudioSessionFailurePolicy {
    static func shouldHandleFailure(
        failedSessionID: UUID?,
        activeSessionID: UUID?,
        pendingStopSessionID: UUID?
    ) -> Bool {
        guard let failedSessionID else { return true }
        return failedSessionID == activeSessionID
            || failedSessionID == pendingStopSessionID
    }
}
