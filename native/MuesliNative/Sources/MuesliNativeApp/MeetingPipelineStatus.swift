import Foundation
import MuesliCore

/// Outcome of one processing stage of a meeting, shown as a status chip in the meeting header.
enum MeetingStageStatus: Equatable {
    case working
    case succeeded
    case failed(reason: String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum MeetingPipelineStatus {
    static func transcription(for meeting: MeetingRecord, isRunning: Bool) -> MeetingStageStatus? {
        if isRunning { return .working }
        let hasTranscript = !meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasTranscript { return .succeeded }
        return meeting.source == .granolaImport ? nil : .failed(reason: "No transcript was captured for this meeting.")
    }

    static func summary(for meeting: MeetingRecord, isRunning: Bool) -> MeetingStageStatus? {
        if isRunning { return .working }
        if let reason = MeetingSummaryClient.summaryFailureReason(from: meeting.formattedNotes) {
            return .failed(reason: reason)
        }
        return meeting.notesState == .structuredNotes ? .succeeded : nil
    }
}
