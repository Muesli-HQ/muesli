import Foundation
import MuesliCore

struct MeetingChatPreparedPrompt {
    let text: String
    let scope: MeetingChatScope
    var isDraft = false
    var needsParticipantName = false
}
enum MeetingChatQuickAction: String, CaseIterable, Identifiable {
    case myNextSteps, decisions, draftFollowUp, weeklyRecap
    var id: String { rawValue }
    var label: String {
        switch self { case .myNextSteps: "My next steps"; case .decisions: "Decisions"; case .draftFollowUp: "Draft follow-up"; case .weeklyRecap: "Weekly recap" }
    }
    func prepare(scope: MeetingChatScope, now: Date, calendar: Calendar, userDisplayName: String?) -> MeetingChatPreparedPrompt {
        switch self {
        case .myNextSteps:
            guard let name = userDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return .init(text: "Which participant’s next steps should I find?", scope: scope, needsParticipantName: true)
            }
            return .init(text: "List next steps explicitly assigned to \(name), with stated owners and deadlines. Cite each source. Distinguish recorded completion from unknown status.", scope: scope)
        case .decisions: return .init(text: "What decisions were agreed in these meetings? Distinguish proposals, agreements, and later changes. Cite each decision.", scope: scope)
        case .draftFollowUp: return .init(text: "Draft a concise follow-up email based on these meetings. Include agreed decisions and next steps with stated owners and dates. Cite sources and flag unknown details.", scope: scope, isDraft: true)
        case .weeklyRecap:
            let today = calendar.startOfDay(for: now)
            let lower = calendar.date(byAdding: .day, value: -6, to: today)!
            let upper = calendar.date(byAdding: .day, value: 1, to: today)!
            var effective = scope
            effective.startDate = max(scope.startDate ?? lower, lower)
            effective.endDateExclusive = min(scope.endDateExclusive ?? upper, upper)
            let through = effective.endDateExclusive!.addingTimeInterval(-1)
            return .init(text: "Summarize meetings from \(effective.startDate!.formatted(date: .abbreviated, time: .omitted)) through \(through.formatted(date: .abbreviated, time: .omitted)). Include decisions, commitments, risks, and unresolved questions with citations. State when coverage is partial.", scope: effective)
        }
    }
}
