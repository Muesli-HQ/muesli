import Foundation
import MuesliCore

enum SalesCRMProvider: String, Codable, CaseIterable, Identifiable {
    case none
    case highLevel
    case hubSpot
    case salesforce

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "No CRM"
        case .highLevel: return "HighLevel"
        case .hubSpot: return "HubSpot"
        case .salesforce: return "Salesforce"
        }
    }
}

struct SalesPreCallBriefingModule: Identifiable, Codable, Equatable {
    enum ModuleKind: String, Codable, CaseIterable, Identifiable {
        case meetingOverview
        case crmSnapshot
        case priorTouchpoints
        case risksAndSignals
        case discoveryQuestions
        case nextBestActions
        case custom

        var id: String { rawValue }
    }

    var id: String
    var kind: ModuleKind
    var title: String
    var instructions: String
    var isEnabled: Bool
    var sortOrder: Int

    static let defaultModules: [SalesPreCallBriefingModule] = [
        SalesPreCallBriefingModule(
            id: "meeting-overview",
            kind: .meetingOverview,
            title: "Meeting Overview",
            instructions: "Show who the call is with, when it starts, and what is known from the calendar.",
            isEnabled: true,
            sortOrder: 10
        ),
        SalesPreCallBriefingModule(
            id: "crm-snapshot",
            kind: .crmSnapshot,
            title: "CRM Snapshot",
            instructions: "Show stage, owner, value, source, recent activity, and open tasks when CRM data is available.",
            isEnabled: true,
            sortOrder: 20
        ),
        SalesPreCallBriefingModule(
            id: "prior-touchpoints",
            kind: .priorTouchpoints,
            title: "Prior Touchpoints",
            instructions: "Summarize prior calls, objections, action items, and customer memory.",
            isEnabled: true,
            sortOrder: 30
        ),
        SalesPreCallBriefingModule(
            id: "risks-signals",
            kind: .risksAndSignals,
            title: "Risks & Signals",
            instructions: "Highlight objections, competitor mentions, stalled next steps, and buying signals.",
            isEnabled: true,
            sortOrder: 40
        ),
        SalesPreCallBriefingModule(
            id: "discovery-questions",
            kind: .discoveryQuestions,
            title: "Discovery Questions",
            instructions: "Give the rep 3 practical questions to ask based on the account and prior context.",
            isEnabled: true,
            sortOrder: 50
        ),
        SalesPreCallBriefingModule(
            id: "next-best-actions",
            kind: .nextBestActions,
            title: "Next Best Actions",
            instructions: "Tell the rep what to do if the call is positive, neutral, or blocked.",
            isEnabled: true,
            sortOrder: 60
        ),
    ]
}

struct SalesCRMRecord: Equatable {
    var provider: SalesCRMProvider
    var accountName: String
    var contactName: String?
    var stage: String?
    var owner: String?
    var value: String?
    var source: String?
    var lastActivity: String?
    var openTasks: [String]
    var customFields: [String: String]
}

struct SalesPreCallBriefingSection: Identifiable, Equatable {
    var id: String
    var title: String
    var body: String
    var bullets: [String]
    var source: String
}

struct SalesPreCallBriefing: Equatable {
    var eventTitle: String
    var startsAt: Date
    var crmProvider: SalesCRMProvider
    var crmStatus: String
    var sections: [SalesPreCallBriefingSection]
}

struct SalesPreCallBriefingDigest: Equatable {
    var heading: String
    var status: String
    var bullets: [String]
}

extension SalesPreCallBriefing {
    func digest(maxBullets: Int = 5) -> SalesPreCallBriefingDigest {
        let preferredKinds = ["crm-snapshot", "risks-signals", "prior-touchpoints", "next-best-actions", "discovery-questions"]
        var selectedBullets: [String] = []

        for sectionID in preferredKinds {
            guard let section = sections.first(where: { $0.id == sectionID }) else { continue }
            selectedBullets.append(contentsOf: section.bullets.prefix(2))
            if selectedBullets.count >= maxBullets { break }
        }

        if selectedBullets.isEmpty {
            selectedBullets = sections.flatMap(\.bullets).prefix(maxBullets).map { $0 }
        }

        return SalesPreCallBriefingDigest(
            heading: "Pre-call brief",
            status: crmStatus,
            bullets: Array(selectedBullets.prefix(maxBullets))
        )
    }
}

enum SalesPreCallBriefingBuilder {
    static func build(
        event: UnifiedCalendarEvent,
        meetings: [MeetingRecord],
        modules: [SalesPreCallBriefingModule],
        crmProvider: SalesCRMProvider,
        crmRecord: SalesCRMRecord? = nil
    ) -> SalesPreCallBriefing {
        let relatedMeetings = relatedMeetings(for: event, meetings: meetings)
        let enabledModules = modules
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }

        let sections = enabledModules.map { module in
            section(
                for: module,
                event: event,
                relatedMeetings: relatedMeetings,
                crmProvider: crmProvider,
                crmRecord: crmRecord
            )
        }

        return SalesPreCallBriefing(
            eventTitle: event.title,
            startsAt: event.startDate,
            crmProvider: crmProvider,
            crmStatus: crmStatus(provider: crmProvider, record: crmRecord),
            sections: sections
        )
    }

    static func relatedMeetings(for event: UnifiedCalendarEvent, meetings: [MeetingRecord]) -> [MeetingRecord] {
        let eventTokens = tokens(from: event.title)
        guard !eventTokens.isEmpty else { return [] }
        return meetings
            .filter { meeting in
                let meetingTokens = tokens(from: meeting.title + " " + meeting.rawTranscript + " " + meeting.formattedNotes)
                return !eventTokens.isDisjoint(with: meetingTokens)
            }
            .sorted { lhs, rhs in
                (parseDate(lhs.startTime) ?? .distantPast) > (parseDate(rhs.startTime) ?? .distantPast)
            }
            .prefix(5)
            .map { $0 }
    }

    private static func section(
        for module: SalesPreCallBriefingModule,
        event: UnifiedCalendarEvent,
        relatedMeetings: [MeetingRecord],
        crmProvider: SalesCRMProvider,
        crmRecord: SalesCRMRecord?
    ) -> SalesPreCallBriefingSection {
        switch module.kind {
        case .meetingOverview:
            return SalesPreCallBriefingSection(
                id: module.id,
                title: module.title,
                body: event.meetingURL == nil ? "Calendar event found. No meeting URL attached." : "Calendar event found with meeting URL.",
                bullets: [
                    "Title: \(event.title)",
                    "Time: \(timeFormatter.string(from: event.startDate))",
                    "Source: \(event.source.rawValue)",
                ],
                source: "Calendar"
            )
        case .crmSnapshot:
            if let crmRecord {
                var bullets = [
                    "Account: \(crmRecord.accountName)",
                    "Stage: \(crmRecord.stage ?? "Unknown")",
                    "Owner: \(crmRecord.owner ?? "Unknown")",
                ]
                if let value = crmRecord.value { bullets.append("Value: \(value)") }
                if let source = crmRecord.source { bullets.append("Source: \(source)") }
                bullets.append(contentsOf: crmRecord.openTasks.prefix(3).map { "Open task: \($0)" })
                return SalesPreCallBriefingSection(
                    id: module.id,
                    title: module.title,
                    body: "CRM context from \(crmRecord.provider.label).",
                    bullets: bullets,
                    source: crmRecord.provider.label
                )
            }
            return SalesPreCallBriefingSection(
                id: module.id,
                title: module.title,
                body: crmProvider == .none ? "No CRM provider selected yet." : "\(crmProvider.label) is selected, but no matching CRM record is available yet.",
                bullets: ["Ready for HighLevel, HubSpot, and Salesforce account/contact payloads."],
                source: "CRM"
            )
        case .priorTouchpoints:
            let bullets = relatedMeetings.isEmpty
                ? ["No prior recorded touchpoints matched this calendar event."]
                : relatedMeetings.prefix(3).map { meeting in
                    "\(meeting.title): \(SalesCallReviewAnalyzer.crmNoteDraft(for: meeting).outcome)"
                }
            return SalesPreCallBriefingSection(
                id: module.id,
                title: module.title,
                body: "\(relatedMeetings.count) related recorded call\(relatedMeetings.count == 1 ? "" : "s") found.",
                bullets: bullets,
                source: "Call history"
            )
        case .risksAndSignals:
            let insights = relatedMeetings.flatMap { SalesCallReviewAnalyzer.callInsights(for: $0) }
            let bullets = insights.isEmpty
                ? ["No prior objections, competitors, or buying signals found."]
                : insights.prefix(5).map { "\($0.name): \($0.guidance)" }
            return SalesPreCallBriefingSection(
                id: module.id,
                title: module.title,
                body: "Signals from prior calls and notes.",
                bullets: bullets,
                source: "Sales intelligence"
            )
        case .discoveryQuestions:
            return SalesPreCallBriefingSection(
                id: module.id,
                title: module.title,
                body: "Suggested questions for the rep.",
                bullets: discoveryQuestions(crmRecord: crmRecord, relatedMeetings: relatedMeetings),
                source: "Sales playbook"
            )
        case .nextBestActions:
            return SalesPreCallBriefingSection(
                id: module.id,
                title: module.title,
                body: "Recommended call plan.",
                bullets: nextBestActions(crmRecord: crmRecord, relatedMeetings: relatedMeetings),
                source: "Sales playbook"
            )
        case .custom:
            return SalesPreCallBriefingSection(
                id: module.id,
                title: module.title,
                body: module.instructions,
                bullets: ["Custom admin module. Connect this to CRM fields or Jessica generation when available."],
                source: "Admin template"
            )
        }
    }

    private static func discoveryQuestions(crmRecord: SalesCRMRecord?, relatedMeetings: [MeetingRecord]) -> [String] {
        var questions = [
            "What does your current documentation workflow look like after patient visits?",
            "Where are you losing the most time today: during the visit, after the visit, or at billing?",
            "Who else needs to feel comfortable before you start using this?"
        ]
        if crmRecord?.stage?.lowercased().contains("trial") == true {
            questions[0] = "What would need to happen in the trial for this to become a no-brainer?"
        }
        if !relatedMeetings.isEmpty {
            questions.append("Last time we discussed a few follow-ups. What changed since then?")
        }
        return Array(questions.prefix(4))
    }

    private static func nextBestActions(crmRecord: SalesCRMRecord?, relatedMeetings: [MeetingRecord]) -> [String] {
        var actions = [
            "If they show interest, keep them live through setup instead of ending with a loose follow-up.",
            "If they ask for info, send it and book the exact next conversation before the call ends.",
            "If a decision-maker is missing, ask for a joint follow-up with that person."
        ]
        if let latest = relatedMeetings.first {
            let memory = SalesCallReviewAnalyzer.customerMemory(from: [latest], fallbackName: latest.title)
            actions.insert("Open with continuity: \(memory.nextBestMove)", at: 0)
        }
        if crmRecord?.openTasks.isEmpty == false {
            actions.insert("Clear the oldest open CRM task on the call.", at: 0)
        }
        return Array(actions.prefix(4))
    }

    private static func crmStatus(provider: SalesCRMProvider, record: SalesCRMRecord?) -> String {
        if let record {
            return "\(record.provider.label) record matched"
        }
        return provider == .none ? "CRM not connected" : "\(provider.label) ready, no record matched"
    }

    private static func tokens(from text: String) -> Set<String> {
        let stopwords: Set<String> = ["call", "demo", "meeting", "skriber", "with", "and", "the", "for", "a", "an"]
        return Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) })
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
