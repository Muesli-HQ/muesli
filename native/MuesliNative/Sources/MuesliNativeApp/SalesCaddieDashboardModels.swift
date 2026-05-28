import Foundation
import MuesliCore

struct SalesCaddieHealthSnapshot: Equatable {
    var microphoneGranted: Bool
    var inputMonitoringGranted: Bool
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool
    var dictationShortcutEnabled: Bool
    var dictationMonitorRunning: Bool
    var computerUseShortcutEnabled: Bool
    var computerUseMonitorRunning: Bool
    var jessicaShortcutEnabled: Bool
    var jessicaMonitorRunning: Bool
    var meetingShortcutEnabled: Bool
    var meetingMonitorRunning: Bool
    var salesAssistEnabled: Bool
    var salesAssistAIEnabled: Bool
    var salesAgentProvider: String
    var supabaseSyncEnabled: Bool

    var allEnabledMonitorsRunning: Bool {
        (!dictationShortcutEnabled || dictationMonitorRunning)
            && (!computerUseShortcutEnabled || computerUseMonitorRunning)
            && (!jessicaShortcutEnabled || jessicaMonitorRunning)
            && (!meetingShortcutEnabled || meetingMonitorRunning)
    }

    var readyForLiveSalesAssist: Bool {
        microphoneGranted && inputMonitoringGranted && salesAssistEnabled
    }
}

struct SalesCallReviewSummary {
    var completedCalls: Int
    var totalMinutes: Int
    var averageMinutes: Int
    var totalWords: Int
    var structuredNotes: Int
    var rawTranscriptFallbacks: Int
    var objectionMentions: Int
    var competitorMentions: Int
    var buyingSignalMentions: Int
    var actionItems: [SalesCallActionItem]
    var callInsights: [SalesCallInsight]
    var scorecards: [SalesCallScorecard]
    var followUpDrafts: [SalesCallFollowUpDraft]
    var crmNoteDrafts: [SalesCallCRMNoteDraft]
    var coachingThemes: [SalesCoachingTheme]
    var customerMemories: [SalesCustomerMemory]
    var recentCalls: [MeetingRecord]

    var structuredNoteRate: Int {
        guard completedCalls > 0 else { return 0 }
        return Int((Double(structuredNotes) / Double(completedCalls) * 100).rounded())
    }

    var averageSalesScore: Int {
        guard !scorecards.isEmpty else { return 0 }
        return scorecards.reduce(0) { $0 + $1.score } / scorecards.count
    }
}

struct SalesCallActionItem: Identifiable, Equatable {
    var id: String
    var meetingID: Int64
    var meetingTitle: String
    var title: String
    var evidence: String
    var priority: String
    var dueHint: String?
}

struct SalesCallInsight: Identifiable, Equatable {
    var id: String
    var meetingID: Int64
    var meetingTitle: String
    var kind: String
    var name: String
    var evidence: String
    var guidance: String
    var priority: String
}

struct SalesCallScorecard: Identifiable, Equatable {
    var id: String
    var meetingID: Int64
    var meetingTitle: String
    var score: Int
    var strengths: [String]
    var coachingGaps: [String]
    var riskFlags: [String]
}

struct SalesCallFollowUpDraft: Identifiable, Equatable {
    var id: String
    var meetingID: Int64
    var meetingTitle: String
    var subject: String
    var body: String
}

struct SalesCallCRMNoteDraft: Identifiable, Equatable {
    var id: String
    var meetingID: Int64
    var meetingTitle: String
    var outcome: String
    var note: String
}

struct SalesCoachingTheme: Identifiable, Equatable {
    var id: String
    var title: String
    var count: Int
    var guidance: String
    var exampleMeetingTitle: String
}

struct SalesCustomerMemory: Identifiable, Equatable {
    var id: String
    var customerName: String
    var callCount: Int
    var latestMeetingID: Int64
    var latestMeetingTitle: String
    var knownSignals: [String]
    var openActionItems: [String]
    var nextBestMove: String
}

enum SalesCallReviewAnalyzer {
    static func summarize(meetings: [MeetingRecord], now: Date = Date(), calendar: Calendar = .current) -> SalesCallReviewSummary {
        let cutoff = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        let recent = meetings
            .filter { meeting in
                guard meeting.status == .completed else { return false }
                guard let date = parseDate(meeting.startTime) else { return true }
                return date >= cutoff
            }
            .sorted { lhs, rhs in
                (parseDate(lhs.startTime) ?? .distantPast) > (parseDate(rhs.startTime) ?? .distantPast)
            }

        let totalSeconds = recent.reduce(0) { $0 + Int($1.durationSeconds.rounded()) }
        let transcriptText = recent.map(\.rawTranscript).joined(separator: "\n").lowercased()
        let structuredNotes = recent.filter { $0.notesState == .structuredNotes }.count
        let fallbackNotes = recent.filter { $0.notesState == .rawTranscriptFallback }.count

        return SalesCallReviewSummary(
            completedCalls: recent.count,
            totalMinutes: totalSeconds / 60,
            averageMinutes: recent.isEmpty ? 0 : (totalSeconds / 60) / recent.count,
            totalWords: recent.reduce(0) { $0 + $1.wordCount },
            structuredNotes: structuredNotes,
            rawTranscriptFallbacks: fallbackNotes,
            objectionMentions: countMatches(in: transcriptText, patterns: objectionPatterns),
            competitorMentions: countMatches(in: transcriptText, patterns: competitorPatterns),
            buyingSignalMentions: countMatches(in: transcriptText, patterns: buyingSignalPatterns),
            actionItems: Array(recent.flatMap { actionItems(for: $0) }.prefix(10)),
            callInsights: Array(recent.flatMap { callInsights(for: $0) }.prefix(12)),
            scorecards: Array(recent.map { scorecard(for: $0) }.prefix(8)),
            followUpDrafts: Array(recent.map { followUpDraft(for: $0) }.prefix(5)),
            crmNoteDrafts: Array(recent.map { crmNoteDraft(for: $0) }.prefix(5)),
            coachingThemes: coachingThemes(from: recent),
            customerMemories: customerMemories(from: recent),
            recentCalls: Array(recent.prefix(6))
        )
    }

    static func actionItems(for meeting: MeetingRecord) -> [SalesCallActionItem] {
        let noteItems = actionLines(from: meeting.formattedNotes)
        let transcriptItems = actionLines(from: meeting.rawTranscript)
        let combined = unique(noteItems + transcriptItems)

        return combined.prefix(8).enumerated().map { index, line in
            SalesCallActionItem(
                id: "action|\(meeting.id)|\(index)|\(stableKey(line))",
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                title: title(fromActionLine: line),
                evidence: line,
                priority: actionPriority(for: line),
                dueHint: dueHint(for: line)
            )
        }
    }

    static func callInsights(for meeting: MeetingRecord) -> [SalesCallInsight] {
        let text = [meeting.rawTranscript, meeting.formattedNotes]
            .joined(separator: "\n")
        let lines = evidenceLines(from: text)
        var insights: [SalesCallInsight] = []

        appendInsights(
            to: &insights,
            meeting: meeting,
            lines: lines,
            kind: "objection",
            name: "Decision-maker / approval risk",
            patterns: [
                "talk to my wife", "talk to my husband", "talk to my partner",
                "talk to her partner", "talk to his partner", "talk to their partner",
                "need approval", "approval",
            ],
            guidance: "Confirm who else needs to weigh in, book the next step while you are live, and give them the exact recap to forward.",
            priority: "high"
        )
        appendInsights(
            to: &insights,
            meeting: meeting,
            lines: lines,
            kind: "objection",
            name: "Send-me-info stall",
            patterns: ["send me info", "send me information", "send me", "email me"],
            guidance: "Send the resource, then keep control by setting a specific follow-up time before ending the call.",
            priority: "medium"
        )
        appendInsights(
            to: &insights,
            meeting: meeting,
            lines: lines,
            kind: "pricing",
            name: "Pricing or card friction",
            patterns: ["too expensive", "price", "pricing", "credit card", "billing"],
            guidance: "Tie price back to saved documentation time, then narrow to the first trial step instead of debating the full purchase.",
            priority: "medium"
        )
        appendInsights(
            to: &insights,
            meeting: meeting,
            lines: lines,
            kind: "competitor",
            name: "Competitor mentioned",
            patterns: competitorPatterns,
            guidance: "Ask what they like and what still feels painful, then position Skriber against that specific gap.",
            priority: "medium"
        )
        appendInsights(
            to: &insights,
            meeting: meeting,
            lines: lines,
            kind: "buying_signal",
            name: "Buying signal",
            patterns: buyingSignalPatterns,
            guidance: "Move immediately into setup, trial start, or the calendar next step while momentum is high.",
            priority: "high"
        )

        let actionItemInsights = actionItems(for: meeting).map { item in
            SalesCallInsight(
                id: "insight|\(meeting.id)|action_item|\(stableKey(item.evidence))",
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                kind: "action_item",
                name: item.title,
                evidence: item.evidence,
                guidance: "Track this as a follow-up owner/date item from the call.",
                priority: item.priority
            )
        }

        return Array(unique(insights + actionItemInsights).prefix(16))
    }

    static func scorecard(for meeting: MeetingRecord) -> SalesCallScorecard {
        let text = callText(for: meeting).lowercased()
        var score = 40
        var strengths: [String] = []
        var gaps: [String] = []
        var risks: [String] = []

        evaluate(
            text: text,
            positivePatterns: discoveryPatterns,
            strength: "Discovery questions showed up",
            gap: "No clear discovery of workflow pain",
            score: &score,
            strengths: &strengths,
            gaps: &gaps
        )
        evaluate(
            text: text,
            positivePatterns: valueDemoPatterns,
            strength: "Connected demo to workflow/value",
            gap: "Demo did not clearly tie back to saved time or workflow",
            score: &score,
            strengths: &strengths,
            gaps: &gaps
        )
        evaluate(
            text: text,
            positivePatterns: nextStepPatterns,
            strength: "Clear next step or setup motion",
            gap: "No clear next step captured",
            score: &score,
            strengths: &strengths,
            gaps: &gaps
        )
        evaluate(
            text: text,
            positivePatterns: buyingSignalPatterns,
            strength: "Buying signal captured",
            gap: "No buying signal captured",
            score: &score,
            strengths: &strengths,
            gaps: &gaps,
            missingPenalty: 0
        )
        if containsAny(text, objectionPatterns) {
            risks.append("Objection or stall language appeared")
            score -= containsAny(text, objectionResolutionPatterns) ? 0 : 8
        }
        if containsAny(text, competitorPatterns) {
            risks.append("Competitor mentioned")
        }
        if containsAny(text, ["send me", "think about it"]) && !containsAny(text, nextStepPatterns) {
            risks.append("Potential no-next-step follow-up risk")
            score -= 10
        }

        return SalesCallScorecard(
            id: "scorecard|\(meeting.id)",
            meetingID: meeting.id,
            meetingTitle: meeting.title,
            score: min(max(score, 0), 100),
            strengths: Array(strengths.prefix(3)),
            coachingGaps: Array(gaps.prefix(3)),
            riskFlags: Array(risks.prefix(3))
        )
    }

    static func followUpDraft(for meeting: MeetingRecord) -> SalesCallFollowUpDraft {
        let insights = callInsights(for: meeting).prefix(3).map(\.name)
        let actions = actionItems(for: meeting).prefix(3).map(\.title)
        let nextStep = actions.first ?? "confirm the next step"
        let signal = insights.first ?? "the conversation"
        let body = """
        Hi,

        Great talking with you today. Based on \(signal.lowercased()), I wanted to send a quick recap and keep the next step simple.

        Next step: \(nextStep).

        I’ll also make sure you have what you need to evaluate Skriber against your current workflow.
        """

        return SalesCallFollowUpDraft(
            id: "followup|\(meeting.id)",
            meetingID: meeting.id,
            meetingTitle: meeting.title,
            subject: "Quick recap from our Skriber call",
            body: body
        )
    }

    static func crmNoteDraft(for meeting: MeetingRecord) -> SalesCallCRMNoteDraft {
        let scorecard = scorecard(for: meeting)
        let insights = callInsights(for: meeting).prefix(4).map { "\($0.kind): \($0.name)" }
        let actions = actionItems(for: meeting).prefix(4).map(\.title)
        let outcome = scorecard.riskFlags.isEmpty ? "Positive call" : "Call with follow-up risk"
        var lines = [
            "Outcome: \(outcome)",
            "Sales score: \(scorecard.score)/100",
        ]
        if !scorecard.strengths.isEmpty {
            lines.append("Strengths: \(scorecard.strengths.joined(separator: "; "))")
        }
        if !scorecard.coachingGaps.isEmpty {
            lines.append("Gaps: \(scorecard.coachingGaps.joined(separator: "; "))")
        }
        if !insights.isEmpty {
            lines.append("Signals: \(insights.joined(separator: "; "))")
        }
        if !actions.isEmpty {
            lines.append("Action items: \(actions.joined(separator: "; "))")
        }

        return SalesCallCRMNoteDraft(
            id: "crm-note|\(meeting.id)",
            meetingID: meeting.id,
            meetingTitle: meeting.title,
            outcome: outcome,
            note: lines.joined(separator: "\n")
        )
    }

    static func customerMemory(from meetings: [MeetingRecord], fallbackName: String) -> SalesCustomerMemory {
        let sorted = meetings.sorted {
            (parseDate($0.startTime) ?? .distantPast) > (parseDate($1.startTime) ?? .distantPast)
        }
        let latest = sorted.first
        let insights = unique(sorted.flatMap { callInsights(for: $0).map(\.name) })
        let actions = unique(sorted.flatMap { actionItems(for: $0).map(\.title) })
        return SalesCustomerMemory(
            id: "memory|\(stableKey(fallbackName))",
            customerName: fallbackName,
            callCount: sorted.count,
            latestMeetingID: latest?.id ?? 0,
            latestMeetingTitle: latest?.title ?? fallbackName,
            knownSignals: Array(insights.prefix(5)),
            openActionItems: Array(actions.prefix(5)),
            nextBestMove: nextBestMove(insights: insights, actions: actions)
        )
    }

    private static let objectionPatterns = [
        "think about it", "talk to my wife", "talk to my husband", "talk to my partner",
        "send me", "too expensive", "credit card", "hipaa", "approval", "not ready",
    ]

    private static let competitorPatterns = [
        "freed", "heidi", "doximity", "dragon", "dax", "nabla", "suki", "abridge", "competitor",
    ]

    private static let buyingSignalPatterns = [
        "how do we get started", "next step", "start the trial", "sounds good", "i like this", "this could work",
    ]

    private static let discoveryPatterns = [
        "how are you", "what are you using", "current workflow", "how do you", "tell me about",
        "what's painful", "what is painful", "how long", "how many", "who else",
    ]

    private static let valueDemoPatterns = [
        "save time", "saves time", "template", "note", "documentation", "workflow", "generate",
        "chart", "patient", "setup", "set up", "try this",
    ]

    private static let nextStepPatterns = [
        "next step", "start the trial", "set up", "setup", "schedule", "book", "follow up",
        "follow-up", "send", "card", "credit card", "trial",
    ]

    private static let objectionResolutionPatterns = [
        "here's how", "what i recommend", "let's", "next step", "we can", "i'll send",
        "i will send", "to solve", "that makes sense",
    ]

    private static func coachingThemes(from meetings: [MeetingRecord]) -> [SalesCoachingTheme] {
        let scorecards = meetings.map(scorecard(for:))
        let gaps = scorecards.flatMap { scorecard in
            scorecard.coachingGaps.map { gap in (gap, scorecard.meetingTitle) }
        }
        let grouped = Dictionary(grouping: gaps, by: { $0.0 })

        let themes: [SalesCoachingTheme] = grouped.map { gap, entries in
            let id = "coaching|\(stableKey(gap))"
            let example = entries.first?.1 ?? "Recent call"
            return SalesCoachingTheme(
                id: id,
                title: gap,
                count: entries.count,
                guidance: coachingGuidance(for: gap),
                exampleMeetingTitle: example
            )
        }

        return Array(themes.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.title < rhs.title : lhs.count > rhs.count
        }.prefix(5))
    }

    private static func customerMemories(from meetings: [MeetingRecord]) -> [SalesCustomerMemory] {
        let grouped = Dictionary(grouping: meetings, by: { customerName(for: $0) })
        let memories: [SalesCustomerMemory] = grouped.map { customerName, customerMeetings in
            customerMemory(from: customerMeetings, fallbackName: customerName)
        }
        let sorted = memories.sorted { lhs, rhs in
            lhs.callCount == rhs.callCount ? lhs.customerName < rhs.customerName : lhs.callCount > rhs.callCount
        }
        return Array(sorted.prefix(6))
    }

    private static func evaluate(
        text: String,
        positivePatterns: [String],
        strength: String,
        gap: String,
        score: inout Int,
        strengths: inout [String],
        gaps: inout [String],
        missingPenalty: Int = 10
    ) {
        if containsAny(text, positivePatterns) {
            strengths.append(strength)
            score += 12
        } else {
            gaps.append(gap)
            score -= missingPenalty
        }
    }

    private static func coachingGuidance(for gap: String) -> String {
        if gap.contains("discovery") {
            return "Coach the rep to ask one workflow and one pain question before demoing."
        }
        if gap.contains("next step") {
            return "Coach the rep to leave every call with a calendar, trial, or setup commitment."
        }
        if gap.contains("Demo") {
            return "Coach the rep to translate features into documentation time saved."
        }
        return "Review the call and turn the gap into one repeatable behavior."
    }

    private static func nextBestMove(insights: [String], actions: [String]) -> String {
        if let action = actions.first {
            return action
        }
        if insights.contains(where: { $0.lowercased().contains("buying") }) {
            return "Move to setup or trial start while momentum is high."
        }
        if insights.contains(where: { $0.lowercased().contains("approval") }) {
            return "Confirm the decision-maker and book a joint follow-up."
        }
        return "Send recap and lock the next scheduled step."
    }

    private static func customerName(for meeting: MeetingRecord) -> String {
        let trimmed = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled customer" }
        return trimmed
            .replacingOccurrences(of: "Skriber", with: "")
            .replacingOccurrences(of: "Call", with: "")
            .replacingOccurrences(of: "Demo", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -|:"))
    }

    private static func callText(for meeting: MeetingRecord) -> String {
        [meeting.rawTranscript, meeting.formattedNotes]
            .joined(separator: "\n")
    }

    private static func countMatches(in text: String, patterns: [String]) -> Int {
        patterns.reduce(0) { count, pattern in
            count + text.components(separatedBy: pattern).count - 1
        }
    }

    private static func appendInsights(
        to insights: inout [SalesCallInsight],
        meeting: MeetingRecord,
        lines: [String],
        kind: String,
        name: String,
        patterns: [String],
        guidance: String,
        priority: String
    ) {
        guard let evidence = firstLine(in: lines, matching: patterns) else { return }
        insights.append(
            SalesCallInsight(
                id: "insight|\(meeting.id)|\(kind)|\(stableKey(name))|\(stableKey(evidence))",
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                kind: kind,
                name: name,
                evidence: evidence,
                guidance: guidance,
                priority: priority
            )
        )
    }

    private static func actionLines(from text: String) -> [String] {
        var inActionSection = false
        var results: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = cleanedLine(rawLine)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            if lower.hasPrefix("#") {
                inActionSection = lower.contains("action")
                    || lower.contains("next step")
                    || lower.contains("follow")
                    || lower.contains("to do")
                continue
            }

            if inActionSection || containsAny(lower, actionPatterns) {
                results.append(line)
            }
        }

        return results
    }

    private static func evidenceLines(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n.!?"))
            .map(cleanedLine)
            .filter { !$0.isEmpty && $0.count >= 8 }
    }

    private static func firstLine(in lines: [String], matching patterns: [String]) -> String? {
        lines.first { line in
            containsAny(line.lowercased(), patterns)
        }
    }

    private static func cleanedLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*•0123456789. "))
    }

    private static func title(fromActionLine line: String) -> String {
        let cleaned = cleanedLine(line)
        guard cleaned.count > 72 else { return cleaned }
        let end = cleaned.index(cleaned.startIndex, offsetBy: 69)
        return String(cleaned[..<end]) + "..."
    }

    private static func actionPriority(for line: String) -> String {
        let lower = line.lowercased()
        if containsAny(lower, ["today", "asap", "urgent", "before", "now", "immediately"]) {
            return "high"
        }
        if containsAny(lower, ["next week", "later", "eventually"]) {
            return "low"
        }
        return "medium"
    }

    private static func dueHint(for line: String) -> String? {
        let lower = line.lowercased()
        for hint in ["today", "tomorrow", "friday", "monday", "next week", "this week"] where lower.contains(hint) {
            return hint
        }
        return nil
    }

    private static let actionPatterns = [
        "action item", "follow up", "follow-up", "next step", "send ", "schedule",
        "book ", "email ", "text ", "call back", "check ", "confirm ", "setup",
        "set up", "create ", "assign ", "i'll ", "i will ", "can you ",
    ]

    private static func containsAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.contains($0) }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let key = stableKey(value)
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func unique(_ values: [SalesCallInsight]) -> [SalesCallInsight] {
        var seen = Set<String>()
        return values.filter { value in
            let key = "\(value.kind)|\(stableKey(value.name))|\(stableKey(value.evidence))"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func stableKey(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
