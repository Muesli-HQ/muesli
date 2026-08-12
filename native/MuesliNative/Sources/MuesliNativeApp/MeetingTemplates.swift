import Foundation
import MuesliCore

struct CustomMeetingTemplate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var prompt: String
    var icon: String

    init(
        id: String = UUID().uuidString,
        name: String,
        prompt: String,
        icon: String = MeetingTemplates.customIconFallback
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.icon = MeetingTemplates.normalizedCustomIcon(named: icon)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case prompt
        case icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        icon = MeetingTemplates.normalizedCustomIcon(
            named: try c.decodeIfPresent(String.self, forKey: .icon)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(MeetingTemplates.normalizedCustomIcon(named: icon), forKey: .icon)
    }
}

struct MeetingTemplateSnapshot: Equatable, Sendable {
    let id: String
    let name: String
    let kind: MeetingTemplateKind
    let prompt: String
}

struct MeetingTemplateDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let category: String?
    let icon: String
    let kind: MeetingTemplateKind
    let promptBody: String

    var snapshot: MeetingTemplateSnapshot {
        MeetingTemplateSnapshot(
            id: id,
            name: title,
            kind: kind,
            prompt: promptBody
        )
    }
}

enum MeetingTemplates {
    static let autoID = "auto"
    static let customIconFallback = "square.and.pencil"

    struct CustomIconOption: Identifiable, Equatable, Sendable {
        let symbolName: String
        let label: String

        var id: String { symbolName }
    }

    static let auto = MeetingTemplateDefinition(
        id: autoID,
        title: "Auto",
        category: nil,
        icon: "sparkles",
        kind: .auto,
        promptBody: """
        Use this structure exactly:

        ## Meeting Summary
        A 2-3 sentence overview of what was discussed.

        ## Key Discussion Points
        - Bullet points of the main topics discussed

        ## Decisions Made
        - Bullet points of any decisions reached

        ## Action Items
        - [ ] Bullet points of tasks assigned or agreed upon, with owners if mentioned

        ## Notable Quotes
        - Any important or notable statements, if applicable
        """
    )

    static let builtIns: [MeetingTemplateDefinition] = [
        MeetingTemplateDefinition(
            id: "one-to-one",
            title: "1 to 1",
            category: "Team",
            icon: "person.2.fill",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Check-In
            A brief summary of how the conversation opened and the overall tone.

            ## Topics Discussed
            - Main themes raised by either person

            ## Support Needed
            - Blockers, concerns, or asks for help

            ## Commitments
            - [ ] Follow-ups or commitments made by either person

            ## Manager Notes
            - Coaching, feedback, or context that should be remembered
            """
        ),
        MeetingTemplateDefinition(
            id: "customer-discovery",
            title: "Customer: Discovery",
            category: "Commercial",
            icon: "person.crop.circle.badge.questionmark",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Customer Context
            - Company, role, or situation if mentioned

            ## Problems and Pain Points
            - Explicit frustrations, blockers, or unmet needs

            ## Current Workflow
            - How they currently solve the problem today

            ## Buying Signals
            - Indicators of urgency, budget, timing, or decision process

            ## Next Steps
            - [ ] Follow-up actions, owners, and dates if mentioned
            """
        ),
        MeetingTemplateDefinition(
            id: "hiring",
            title: "Hiring",
            category: "Recruiting",
            icon: "briefcase.fill",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Candidate Snapshot
            A concise overview of the candidate and relevant background.

            ## Strengths
            - Positive signals from the conversation

            ## Concerns
            - Risks, gaps, or open questions

            ## Role Fit
            - Why they do or do not fit the role as discussed

            ## Decision and Next Steps
            - [ ] Hiring decision, interview progression, or follow-up items
            """
        ),
        MeetingTemplateDefinition(
            id: "stand-up",
            title: "Stand-Up",
            category: "Team",
            icon: "figure.stand",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Yesterday
            - Work completed or progress since the last update

            ## Today
            - Planned work or priorities for today

            ## Blockers
            - Risks, delays, or dependencies

            ## Coordination Notes
            - Decisions, asks, or cross-team alignment points
            """
        ),
        MeetingTemplateDefinition(
            id: "weekly-team-meeting",
            title: "Weekly Team Meeting",
            category: "Team",
            icon: "calendar",
            kind: .builtin,
            promptBody: """
            Use this structure exactly:

            ## Weekly Overview
            A concise summary of the most important updates from the meeting.

            ## Progress Updates
            - Key workstreams and status changes

            ## Decisions
            - Decisions made or confirmed

            ## Risks and Open Questions
            - Issues that need attention or follow-up

            ## Action Items
            - [ ] Tasks, owners, and timing if mentioned
            """
        ),
    ]

    static let customIconOptions: [CustomIconOption] = [
        CustomIconOption(symbolName: "square.and.pencil", label: "Notes"),
        CustomIconOption(symbolName: "person.2.fill", label: "1 to 1"),
        CustomIconOption(symbolName: "person.crop.circle.badge.questionmark", label: "Discovery"),
        CustomIconOption(symbolName: "briefcase.fill", label: "Hiring"),
        CustomIconOption(symbolName: "calendar", label: "Weekly"),
        CustomIconOption(symbolName: "figure.stand", label: "Stand-Up"),
        CustomIconOption(symbolName: "person.fill.questionmark", label: "Interview"),
        CustomIconOption(symbolName: "person.fill.checkmark", label: "Review"),
        CustomIconOption(symbolName: "building.2.fill", label: "Business"),
        CustomIconOption(symbolName: "chart.line.uptrend.xyaxis", label: "Strategy"),
        CustomIconOption(symbolName: "dollarsign.circle", label: "Sales"),
        CustomIconOption(symbolName: "megaphone.fill", label: "Marketing"),
        CustomIconOption(symbolName: "hammer.fill", label: "Execution"),
        CustomIconOption(symbolName: "shippingbox.fill", label: "Ops"),
        CustomIconOption(symbolName: "doc.text.fill", label: "Docs"),
        CustomIconOption(symbolName: "checklist", label: "Checklist"),
        CustomIconOption(symbolName: "lightbulb.fill", label: "Ideas"),
        CustomIconOption(symbolName: "waveform.path.ecg", label: "Health"),
        CustomIconOption(symbolName: "graduationcap.fill", label: "Learning"),
        CustomIconOption(symbolName: "globe", label: "Global"),
        CustomIconOption(symbolName: "phone.fill", label: "Calls"),
        CustomIconOption(symbolName: "message.fill", label: "Conversation"),
        CustomIconOption(symbolName: "person.3.fill", label: "Team"),
        CustomIconOption(symbolName: "target", label: "Goals"),
        CustomIconOption(symbolName: "flag.fill", label: "Milestones"),
        CustomIconOption(symbolName: "sparkles", label: "Enhanced"),
        CustomIconOption(symbolName: "wand.and.stars", label: "Creative"),
        CustomIconOption(symbolName: "paperplane.fill", label: "Launch"),
        CustomIconOption(symbolName: "gearshape.fill", label: "Systems"),
        CustomIconOption(symbolName: "folder.fill", label: "Projects"),
        CustomIconOption(symbolName: "clock.fill", label: "Timeline"),
        CustomIconOption(symbolName: "bolt.fill", label: "Sprint"),
    ]

    static func normalizedCustomIcon(named icon: String?) -> String {
        let trimmed = icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return customIconFallback }
        // Older configs stored rocket.fill for launch-style templates; remap it for compatibility.
        if trimmed == "rocket.fill" {
            return "paperplane.fill"
        }
        return customIconOptions.contains(where: { $0.symbolName == trimmed }) ? trimmed : customIconFallback
    }

    static func customDefinition(from customTemplate: CustomMeetingTemplate) -> MeetingTemplateDefinition {
        MeetingTemplateDefinition(
            id: customTemplate.id,
            title: customTemplate.name,
            category: "Custom",
            icon: normalizedCustomIcon(named: customTemplate.icon),
            kind: .custom,
            promptBody: customTemplate.prompt
        )
    }

    static func customDefinitions(from customTemplates: [CustomMeetingTemplate]) -> [MeetingTemplateDefinition] {
        customTemplates.map(customDefinition)
    }

    static func allDefinitions(customTemplates: [CustomMeetingTemplate]) -> [MeetingTemplateDefinition] {
        [auto] + builtIns + customDefinitions(from: customTemplates)
    }

    static func resolveDefinition(
        id: String?,
        customTemplates: [CustomMeetingTemplate],
        defaultTemplateID: String? = nil
    ) -> MeetingTemplateDefinition {
        let normalizedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // When no explicit template is set, fall back to the configured default
        // template (if any) before the hardcoded Auto backstop.
        let effectiveID: String
        if normalizedID.isEmpty || normalizedID == autoID {
            let normalizedDefault = defaultTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            effectiveID = normalizedDefault.isEmpty ? autoID : normalizedDefault
        } else {
            effectiveID = normalizedID
        }
        if effectiveID == autoID {
            return auto
        }
        if let builtIn = builtIns.first(where: { $0.id == effectiveID }) {
            return builtIn
        }
        if let custom = customTemplates.first(where: { $0.id == effectiveID }) {
            return customDefinition(from: custom)
        }
        // Configured default may reference a deleted template; fall back to Auto.
        return auto
    }

    static func resolveExactDefinition(id: String?, customTemplates: [CustomMeetingTemplate]) -> MeetingTemplateDefinition? {
        let normalizedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? autoID
        if normalizedID.isEmpty || normalizedID == autoID {
            return auto
        }
        if let builtIn = builtIns.first(where: { $0.id == normalizedID }) {
            return builtIn
        }
        if let custom = customTemplates.first(where: { $0.id == normalizedID }) {
            return customDefinition(from: custom)
        }
        return nil
    }

    static func resolveSnapshot(
        id: String?,
        customTemplates: [CustomMeetingTemplate],
        defaultTemplateID: String? = nil
    ) -> MeetingTemplateSnapshot {
        resolveDefinition(id: id, customTemplates: customTemplates, defaultTemplateID: defaultTemplateID).snapshot
    }

    static func resolveExactSnapshot(id: String?, customTemplates: [CustomMeetingTemplate]) -> MeetingTemplateSnapshot? {
        resolveExactDefinition(id: id, customTemplates: customTemplates)?.snapshot
    }

    static func snapshot(
        for meeting: MeetingRecord,
        customTemplates: [CustomMeetingTemplate],
        defaultTemplateID: String? = nil
    ) -> MeetingTemplateSnapshot {
        let storedID = meeting.selectedTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedName = meeting.selectedTemplateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedPrompt = meeting.selectedTemplatePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedID.isEmpty, !storedName.isEmpty, !storedPrompt.isEmpty {
            return MeetingTemplateSnapshot(
                id: storedID,
                name: storedName,
                kind: meeting.selectedTemplateKind ?? .auto,
                prompt: storedPrompt
            )
        }
        return resolveSnapshot(
            id: storedID.isEmpty ? nil : storedID,
            customTemplates: customTemplates,
            defaultTemplateID: defaultTemplateID
        )
    }
}
