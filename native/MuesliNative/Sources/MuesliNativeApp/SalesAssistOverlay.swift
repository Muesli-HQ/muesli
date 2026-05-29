import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let salesAssistTranscriptChunk = Notification.Name("SalesAssistTranscriptChunk")
}

struct SalesAssistAlert: Equatable {
    let kind: String
    let objection: String
    let quote: String
    let talkTrack: String
    let priority: String
    let updatedAt: Date

    var fingerprint: String {
        [
            kind,
            objection,
            String(quote.suffix(120)),
        ]
        .joined(separator: "|")
        .lowercased()
    }
}

enum SalesAssistOverlayAction {
    case dismiss
    case snooze
    case useful
    case notUseful
    case disableForSession
}

@MainActor
final class SalesAssistController {
    private let configProvider: () -> AppConfig
    private let alertHandler: (SalesAssistAlert) -> Void
    private let feedbackHandler: (SalesAssistAlert, SalesAssistOverlayAction) -> Void
    private var observer: NSObjectProtocol?
    private var panel: NSPanel?
    private lazy var engine = SalesAssistEngine(
        configProvider: configProvider,
        alertHandler: alertHandler
    ) { [weak self] alerts in
        self?.showActiveAlerts(alerts)
    }

    init(
        configProvider: @escaping () -> AppConfig,
        alertHandler: @escaping (SalesAssistAlert) -> Void = { _ in },
        feedbackHandler: @escaping (SalesAssistAlert, SalesAssistOverlayAction) -> Void = { _, _ in }
    ) {
        self.configProvider = configProvider
        self.alertHandler = alertHandler
        self.feedbackHandler = feedbackHandler
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .salesAssistTranscriptChunk,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let speaker = notification.userInfo?["speaker"] as? String ?? "Transcript"
            let text = notification.userInfo?["text"] as? String ?? ""
            Task { @MainActor in
                self.handleTranscriptLine("\(speaker): \(text)")
            }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine.reset()
        close()
    }

    func showTestAlert() {
        handleTranscriptLine("Prospect: I like this. How do we get started with the trial?")
    }

    func showSampleAlert(kind: String) {
        let sample: SalesAssistAlert
        switch kind {
        case "competitor":
            sample = SalesAssistAlert(
                kind: "competitor",
                objection: "Already using competitor",
                quote: "Prospect: We are already using Freed for most of our notes.",
                talkTrack: "Ask what Freed handles well and what still takes work. Then offer a side-by-side trial using their specialty templates.",
                priority: "medium",
                updatedAt: Date()
            )
        case "discovery":
            sample = SalesAssistAlert(
                kind: "discovery",
                objection: "Quantify the pain",
                quote: "Prospect: Charting takes forever and I end up doing notes at night.",
                talkTrack: "Ask: \"How many minutes per patient does that usually cost you, and how many patients do you see on a normal day?\"",
                priority: "medium",
                updatedAt: Date()
            )
        case "talk_ratio":
            sample = SalesAssistAlert(
                kind: "talk_ratio",
                objection: "Let the prospect talk",
                quote: "Rep has carried most of the last few turns.",
                talkTrack: "Ask a short question and stop: \"What part of your note workflow would you most want fixed first?\"",
                priority: "low",
                updatedAt: Date()
            )
        case "objection":
            sample = SalesAssistAlert(
                kind: "pricing",
                objection: "Card resistance",
                quote: "Prospect: Why do you need a credit card for a free trial?",
                talkTrack: "Nothing charges during the trial. The card just keeps the account live if you decide to continue. If it doesn't save time, we cancel before anything bills.",
                priority: "high",
                updatedAt: Date()
            )
        default:
            sample = SalesAssistAlert(
                kind: "buying_signal",
                objection: "Buying signal",
                quote: "Prospect: I like this. How do we get started with the trial?",
                talkTrack: "They gave you permission to close. Tie it to their pain in one sentence, then start the trial setup now.",
                priority: "medium",
                updatedAt: Date()
            )
        }
        engine.presentManual(alerts: [sample])
    }

    private func handleTranscriptLine(_ line: String) {
        engine.handleTranscriptLine(line)
    }

    private func showActiveAlerts(_ activeAlerts: [SalesAssistAlert]) {
        guard !activeAlerts.isEmpty else {
            close()
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        let height = SalesAssistOverlayView.height(for: activeAlerts.count)
        panel.setContentSize(NSSize(width: 560, height: height))
        panel.contentView = NSHostingView(
            rootView: SalesAssistOverlayView(alerts: activeAlerts) { [weak self] alert, action in
                self?.handleOverlayAction(action, for: alert)
            }
        )
        position(panel)
        panel.orderFrontRegardless()
    }

    private func handleOverlayAction(_ action: SalesAssistOverlayAction, for alert: SalesAssistAlert) {
        if action == .useful || action == .notUseful {
            feedbackHandler(alert, action)
        }
        _ = engine.handleAction(action, for: alert)
    }

    private func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

private struct SalesAssistOverlayView: View {
    let alerts: [SalesAssistAlert]
    let onAction: (SalesAssistAlert, SalesAssistOverlayAction) -> Void

    static func height(for alertCount: Int) -> CGFloat {
        let count = max(1, min(alertCount, 2))
        return CGFloat(72 + (count * 248) + ((count - 1) * 10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Sales Assist")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.64))
                    .textCase(.uppercase)
                Spacer()
                Text("\(alerts.count) live cue\(alerts.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.58))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
                Button {
                    if let firstAlert = alerts.first {
                        onAction(firstAlert, .disableForSession)
                    }
                } label: {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Turn off overlay for this call")
                Button {
                    alerts.forEach { onAction($0, .dismiss) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.72))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            ForEach(alerts, id: \.fingerprint) { alert in
                SalesAssistOverlayCard(alert: alert, onAction: { action in
                    onAction(alert, action)
                })
            }
        }
        .padding(14)
        .frame(width: 560, height: Self.height(for: alerts.count), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct SalesAssistOverlayCard: View {
    let alert: SalesAssistAlert
    let onAction: (SalesAssistOverlayAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(priorityColor)
                    .frame(width: 18)
                Text(kindLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(priorityColor)
                Text(alert.priority.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(priorityColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(priorityColor.opacity(0.16), in: Capsule())
                Spacer()
                iconButton("hand.thumbsup", help: "Useful") { onAction(.useful) }
                iconButton("hand.thumbsdown", help: "Not useful") { onAction(.notUseful) }
                iconButton("clock", help: "Snooze") { onAction(.snooze) }
                iconButton("xmark", help: "Dismiss") { onAction(.dismiss) }
            }

            Text(alert.objection)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)

            Text(alert.quote)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.64))
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Recommended response")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(priorityColor.opacity(0.9))
                    .textCase(.uppercase)
                Text(alert.talkTrack)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 248, maxHeight: 248, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(priorityColor.opacity(0.42), lineWidth: 1)
        )
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.70))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var priorityColor: Color {
        switch alert.priority {
        case "high":
            return Color(red: 1.0, green: 0.50, blue: 0.37)
        case "low":
            return Color(red: 0.65, green: 0.73, blue: 0.82)
        default:
            return alert.kind == "buying_signal" || alert.kind == "close"
                ? Color(red: 0.36, green: 0.86, blue: 0.52)
                : Color(red: 0.42, green: 0.72, blue: 1.0)
        }
    }

    private var iconName: String {
        switch alert.kind {
        case "buying_signal", "close":
            return "flag.checkered"
        case "competitor":
            return "rectangle.2.swap"
        case "discovery":
            return "questionmark.bubble.fill"
        case "talk_ratio":
            return "timer"
        case "pricing":
            return "dollarsign.circle.fill"
        default:
            return "exclamationmark.bubble.fill"
        }
    }

    private var kindLabel: String {
        switch alert.kind {
        case "buying_signal":
            return "Buying signal"
        case "close":
            return "Close now"
        case "competitor":
            return "Battlecard"
        case "discovery":
            return "Discovery prompt"
        case "talk_ratio":
            return "Talk time"
        case "pricing":
            return "Pricing guidance"
        default:
            return "Objection"
        }
    }
}

final class SalesAssistDetector {
    private struct SalesMomentCategory {
        let name: String
        let kind: String
        let priority: String
        let cues: [NSRegularExpression]
        let talkTrack: String
    }

    private let categories: [SalesMomentCategory]
    private let salesMomentCues: [NSRegularExpression]

    init() {
        categories = [
            Self.category(
                name: "Partner approval",
                kind: "objection",
                priority: "high",
                cues: [
                    #"\b(talk|check|run it|discuss|ask|show)\b.{0,90}\b(wife|husband|spouse|partner|partners|office manager|admin|team|boss|owner|owners|doctor|provider|providers|decision maker)\b"#,
                    #"\b(wife|husband|spouse|partner|office manager|admin|team|boss|owner|doctor|provider|decision maker)\b.{0,90}\b(needs?|has to|have to|should|will want|decide|approve|sign off)\b"#,
                ],
                talkTrack: "Totally fair. Let's make this easy to show them: I'll set up the trial now, build the templates, and you can both test it with real visits before anything bills."
            ),
            Self.category(
                name: "Decision hesitation",
                kind: "objection",
                priority: "high",
                cues: [
                    #"\b(i|we)\b.{0,20}\b(need|want|have)\b.{0,50}\b(think about it|sleep on it|mull it over)\b"#,
                    #"\b(not sure|unsure|on the fence|need more time|let me think|think about it)\b"#,
                ],
                talkTrack: "That makes sense. The lowest-risk way to think about it is to start the trial and judge it from real notes, not a sales call. Let's get the account live and you can decide with evidence."
            ),
            Self.category(
                name: "Send information soft exit",
                kind: "objection",
                priority: "high",
                cues: [
                    #"\b(send|email|text)\b.{0,50}\b(info|information|details|something|brochure|pricing|link|materials)\b"#,
                    #"\b(can you|could you|just)\b.{0,40}\b(send|email|text)\b"#,
                ],
                talkTrack: "I can send that, but it usually lands better after we anchor it to your workflow. Let's take 90 seconds now and I'll show you the exact next step."
            ),
            Self.category(
                name: "Card resistance",
                kind: "pricing",
                priority: "high",
                cues: [
                    #"(\b(card|credit card|payment|billing)\b.{0,90}\b(don't|dont|do not|not comfortable|why|need|have to|required|free|trial)\b|\b(why|need|have to|required)\b.{0,90}\b(card|credit card|payment|billing)\b)"#,
                    #"\b(not giving|don't want to give|dont want to give)\b.{0,50}\b(card|credit card|payment)\b"#,
                ],
                talkTrack: "Nothing charges during the trial. The card just keeps the account live if you decide to continue. If it doesn't save you time, we cancel before anything bills."
            ),
            Self.category(
                name: "Too expensive",
                kind: "pricing",
                priority: "medium",
                cues: [
                    #"\b(expensive|cost|price|pricing|budget|too much|afford|cheap|cheaper)\b"#,
                    #"\b(can't|cannot|won't)\b.{0,40}\b(pay|spend|afford|budget)\b"#,
                ],
                talkTrack: "Totally. The easiest way to judge it is visits saved, not monthly fee. If it saves even one admin hour or one late-night charting block, it usually pays for itself."
            ),
            Self.category(
                name: "Already using competitor",
                kind: "competitor",
                priority: "medium",
                cues: [
                    #"\b(already use|using|tried|have)\b.{0,80}\b(dragon|heidi|nabla|abridge|dax|freed|doximity|suki|deepscribe|scribe|competitor|another tool|other tool)\b"#,
                    #"\b(dragon|heidi|nabla|abridge|dax|freed|doximity|suki|deepscribe)\b"#,
                ],
                talkTrack: "Good signal. Ask what they like and what still takes work, then suggest a side-by-side trial using their specialty templates. Don't attack the tool; make Skriber win on workflow."
            ),
            Self.category(
                name: "No time",
                kind: "objection",
                priority: "medium",
                cues: [
                    #"\b(no time|too busy|busy right now|not a good time|bad time|later|call me back|in a meeting)\b"#,
                    #"\b(can't|cannot)\b.{0,40}\b(now|today|talk|meet|do this)\b"#,
                ],
                talkTrack: "That's exactly why we keep setup lightweight. Give me two minutes to get the account started, then you can test it when you're between patients."
            ),
            Self.category(
                name: "Buying signal",
                kind: "buying_signal",
                priority: "medium",
                cues: [
                    #"\b(i like|sounds good|this is good|that would help|that's helpful|this could work|interested|makes sense)\b"#,
                    #"\b(how|what)\b.{0,50}\b(start|get started|sign up|trial|next step|move forward)\b"#,
                ],
                talkTrack: "They gave you permission to close. Tie it to their pain in one sentence, then start the trial setup now while they are live."
            ),
            Self.category(
                name: "Close the trial",
                kind: "close",
                priority: "high",
                cues: [
                    #"\b(let's do it|sign me up|get me started|start the trial|set it up|ready to start|move forward)\b"#,
                    #"\b(what do you need from me|where do i enter|how do i pay|create my account)\b"#,
                ],
                talkTrack: "Move immediately to setup. Ask for the best email, confirm specialty, and keep talking while the account and templates are created."
            ),
            Self.category(
                name: "Quantify the pain",
                kind: "discovery",
                priority: "medium",
                cues: [
                    #"\b(charting|notes?|documentation|admin|paperwork)\b.{0,80}\b(takes?|spend|late|after hours|night|weekend|behind|too long)\b"#,
                    #"\b(spend|takes?)\b.{0,80}\b(hours?|minutes?)\b.{0,80}\b(notes?|charting|documentation|paperwork)\b"#,
                ],
                talkTrack: "Pause the demo and quantify it: \"How many minutes per patient does that usually cost you, and how many patients do you see on a normal day?\""
            ),
            Self.category(
                name: "Map the EHR workflow",
                kind: "discovery",
                priority: "low",
                cues: [
                    #"\b(epic|athena|cerner|modmed|eclinicalworks|ecw|practice fusion|simplepractice|ehr|emr)\b"#,
                    #"\b(copy paste|integrat(e|ion)|template|checkbox|macro)\b"#,
                ],
                talkTrack: "Ask one workflow question before pitching: \"Where does the note need to land in your EHR, and what part is most annoying today?\""
            ),
        ]

        salesMomentCues = Self.compile([
            #"\b(no|not|don't|dont|can't|cannot|won't|wouldn't|isn't|doesn't)\b"#,
            #"\b(concern|worried|hesitant|problem|issue|objection|hangup|deal breaker|risk)\b"#,
            #"\b(need|want|have)\b.{0,60}\b(think|ask|check|wait|pause|hold off|talk|discuss|review)\b"#,
            #"\b(later|maybe|not now|not today|send me|email me|call me back)\b"#,
            #"\b(expensive|price|cost|budget|afford|card|payment|billing|contract|commitment)\b"#,
            #"\b(interested|sounds good|i like|makes sense|get started|sign up|trial|move forward)\b"#,
        ])
    }

    func detect(line: String, config: AppConfig = AppConfig()) -> SalesAssistAlert? {
        detect(lines: [line], config: config)
    }

    func detect(lines: [String], config: AppConfig) -> SalesAssistAlert? {
        detectAlerts(lines: lines, config: config).first
    }

    func detectAlerts(lines: [String], config: AppConfig) -> [SalesAssistAlert] {
        let prospectText = relevantProspectText(from: lines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationText = relevantConversationText(from: lines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prospectText.isEmpty || !conversationText.isEmpty else { return [] }

        let enabledKinds = Set(config.salesAssistEnabledKinds)
        var alerts: [SalesAssistAlert] = []

        if enabledKinds.contains("talk_ratio"), let talkRatioAlert = talkRatioAlert(lines: lines) {
            alerts.append(talkRatioAlert)
        }

        let categoryAlerts = categories
            .filter({ enabledKinds.contains($0.kind) })
            .compactMap { category -> (SalesMomentCategory, String, Int)? in
                let text = category.kind == "competitor" ? conversationText : prospectText
                guard !text.isEmpty else { return nil }
                if category.kind == "competitor",
                   customCompetitorCueMatches(text: text, config: config) {
                    return nil
                }
                guard !isCategorySuppressedByTuning(category, text: text, config: config) else { return nil }
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                return (category, text, Self.score(category: category, text: text, range: range))
            }
            .filter({ $0.2 > 0 })
            .sorted(by: { $0.2 > $1.2 })
            .prefix(3)
            .map { alert(for: $0.0, quote: $0.1) }
        alerts.append(contentsOf: categoryAlerts)

        if enabledKinds.contains("objection") {
            let customAlerts = config.salesAssistObjections
            .compactMap({ customAlert(for: $0, quote: prospectText, config: config) })
            .prefix(2)
            alerts.append(contentsOf: customAlerts)
        }

        let customCueAlerts = config.salesAssistLiveCues
            .filter({ enabledKinds.contains($0.kind) })
            .compactMap { cue in
                customAlertWithScore(
                    for: cue,
                    quote: cue.kind == "competitor" ? conversationText : prospectText
                )
            }
            .sorted(by: { $0.score > $1.score })
            .map(\.alert)
            .prefix(2)
        alerts.append(contentsOf: customCueAlerts)

        if enabledKinds.contains("discovery"),
           !alerts.contains(where: { $0.kind == "discovery" }),
           let discoveryAlert = discoveryQuestionAlert(for: prospectText) {
            alerts.append(discoveryAlert)
        }

        if alerts.isEmpty,
           enabledKinds.contains("objection"),
           !prospectText.isEmpty,
           {
               let range = NSRange(prospectText.startIndex..<prospectText.endIndex, in: prospectText)
               return salesMomentCues.contains { $0.firstMatch(in: prospectText, options: [], range: range) != nil }
           }() {
            alerts.append(
                SalesAssistAlert(
                    kind: "objection",
                    objection: "New objection",
                    quote: String(prospectText.suffix(260)),
                    talkTrack: "Pause and label it first: \"That sounds like the main concern.\" Then ask one clarifying question: \"Is this about fit, timing, cost, or trust?\" Once they answer, tie the trial to that specific concern.",
                    priority: "medium",
                    updatedAt: Date()
                )
            )
        }

        var seen = Set<String>()
        return alerts
            .filter { alert in
                let group = Self.alertGroup(alert)
                guard !seen.contains(group) else { return false }
                seen.insert(group)
                return true
            }
            .sorted { lhs, rhs in
                let left = Self.priorityScore(lhs.priority)
                let right = Self.priorityScore(rhs.priority)
                if left != right { return left > right }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(3)
            .map { $0 }
    }

    private func relevantConversationText(from lines: [String]) -> String {
        lines.suffix(4)
            .map { line in
                line
                    .replacingOccurrences(of: #"(?i)^.*?\b(Prospect|Rep|Transcript):\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func shouldAskClassifier(
        lines: [String],
        localAlert: SalesAssistAlert?,
        config: AppConfig
    ) -> Bool {
        let normalized = lines.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prospectText = relevantProspectText(from: lines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let conversationText = relevantConversationText(from: lines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prospectText.count >= 18 || normalized.count >= 18 else { return false }

        if localAlert?.objection == "New objection" {
            return true
        }

        if config.salesAssistObjections.contains(where: { customObjectionMatches($0, text: prospectText, config: config) }) {
            return true
        }

        if config.salesAssistLiveCues.contains(where: {
            customCueMatches($0, text: $0.kind == "competitor" ? conversationText : prospectText)
        }) {
            return true
        }

        let range = NSRange(prospectText.startIndex..<prospectText.endIndex, in: prospectText)
        return salesMomentCues.contains { regex in
            regex.firstMatch(in: prospectText, options: [], range: range) != nil
        }
    }

    private func relevantProspectText(from lines: [String]) -> String {
        var sawSpeakerLabel = false
        let prospectLines = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.localizedCaseInsensitiveContains("Prospect:") {
                sawSpeakerLabel = true
                return trimmed.replacingOccurrences(
                    of: #"(?i)^.*?\bProspect:\s*"#,
                    with: "",
                    options: .regularExpression
                )
            }
            if trimmed.range(of: #"(?i)^Rep:"# , options: .regularExpression) != nil {
                sawSpeakerLabel = true
                return nil
            }
            return nil
        }

        if !prospectLines.isEmpty {
            return prospectLines.suffix(3).joined(separator: " ")
        }

        if sawSpeakerLabel {
            return ""
        }

        return lines.suffix(1).joined(separator: " ")
    }

    private func alert(for category: SalesMomentCategory, quote: String) -> SalesAssistAlert {
        return SalesAssistAlert(
            kind: category.kind,
            objection: category.name,
            quote: String(quote.suffix(260)),
            talkTrack: category.talkTrack,
            priority: category.priority,
            updatedAt: Date()
        )
    }

    private func customAlert(for objection: SalesAssistObjection, quote: String, config: AppConfig) -> SalesAssistAlert? {
        guard customObjectionMatches(objection, text: quote, config: config) else { return nil }
        let name = objection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let guidance = objection.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        return SalesAssistAlert(
            kind: "objection",
            objection: name.isEmpty ? "Custom objection" : name,
            quote: String(quote.suffix(260)),
            talkTrack: guidance.isEmpty
                ? "Pause and label the concern, then ask one clarifying question before moving forward."
                : guidance,
            priority: Self.normalizedPriority(objection.priority),
            updatedAt: Date()
        )
    }

    private func customAlert(for cue: SalesAssistLiveCue, quote: String) -> SalesAssistAlert? {
        customAlertWithScore(for: cue, quote: quote)?.alert
    }

    private func customAlertWithScore(for cue: SalesAssistLiveCue, quote: String) -> (alert: SalesAssistAlert, score: Int)? {
        let score = customCueScore(cue, text: quote)
        guard score > 0 else { return nil }
        let name = cue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let guidance = cue.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            SalesAssistAlert(
            kind: Self.normalizedKind(cue.kind),
            objection: name.isEmpty ? SalesAssistLiveCue.kindLabels[cue.kind] ?? "Live cue" : name,
            quote: String(quote.suffix(260)),
            talkTrack: guidance.isEmpty
                ? "Pause and ask one short question before moving forward."
                : guidance,
            priority: Self.normalizedPriority(cue.priority),
            updatedAt: Date()
            ),
            score
        )
    }

    private func customObjectionMatches(_ objection: SalesAssistObjection, text: String, config: AppConfig) -> Bool {
        let phrases = Self.customTriggerPhrases(from: objection.triggerPhrases)
            + config.salesAssistObjectionTuningExamples
                .filter { $0.objectionID == objection.id && $0.outcome == .accepted }
                .map(\.phrase)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !phrases.isEmpty else { return false }
        let lowercased = text.lowercased()
        if hasFalsePositiveExample(for: objection, text: lowercased, config: config) {
            return false
        }
        return phrases.contains { lowercased.contains($0.lowercased()) }
    }

    private func isCategorySuppressedByTuning(
        _ category: SalesMomentCategory,
        text: String,
        config: AppConfig
    ) -> Bool {
        guard let objection = config.salesAssistObjections.first(where: {
            Self.normalizedLabel($0.name) == Self.normalizedLabel(category.name)
        }) else {
            return false
        }
        return hasFalsePositiveExample(for: objection, text: text.lowercased(), config: config)
    }

    private func hasFalsePositiveExample(
        for objection: SalesAssistObjection,
        text: String,
        config: AppConfig
    ) -> Bool {
        config.salesAssistObjectionTuningExamples
            .filter { $0.objectionID == objection.id && $0.outcome == .falsePositive }
            .map(\.phrase)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 3 }
            .contains { text.contains($0) }
    }

    private func customCueMatches(_ cue: SalesAssistLiveCue, text: String) -> Bool {
        customCueScore(cue, text: text) > 0
    }

    private func customCompetitorCueMatches(text: String, config: AppConfig) -> Bool {
        config.salesAssistLiveCues
            .filter { $0.kind == "competitor" }
            .contains { customCueMatches($0, text: text) }
    }

    private func customCueScore(_ cue: SalesAssistLiveCue, text: String) -> Int {
        let phrases = Self.customTriggerPhrases(from: cue.triggerPhrases)
        guard !phrases.isEmpty else { return 0 }
        let lowercased = text.lowercased()
        return phrases.reduce(0) { score, phrase in
            guard lowercased.contains(phrase.lowercased()) else { return score }
            return score + max(phrase.count, 3)
        }
    }

    private func talkRatioAlert(lines: [String]) -> SalesAssistAlert? {
        let recent = Array(lines.suffix(6))
        let repLines = recent.filter { $0.localizedCaseInsensitiveContains("Rep:") }
        guard repLines.count >= 4 else { return nil }
        let repChars = repLines.reduce(0) { $0 + $1.count }
        let prospectChars = recent
            .filter { $0.localizedCaseInsensitiveContains("Prospect:") }
            .reduce(0) { $0 + $1.count }
        guard repChars >= 360, repChars > max(120, prospectChars * 3) else { return nil }
        return SalesAssistAlert(
            kind: "talk_ratio",
            objection: "Let the prospect talk",
            quote: "Rep has carried most of the last few turns.",
            talkTrack: "Ask a short question and stop: \"Before I keep going, what part of your note workflow would you most want fixed first?\"",
            priority: "low",
            updatedAt: Date()
        )
    }

    private func discoveryQuestionAlert(for text: String) -> SalesAssistAlert? {
        let lowercased = text.lowercased()
        guard lowercased.count >= 18 else { return nil }

        let question: (name: String, priority: String, response: String)?
        if Self.containsAny(lowercased, ["after hours", "late at night", "behind"])
            || (
                Self.containsAny(lowercased, ["charting", "documentation", "notes", "paperwork"])
                && Self.containsAny(lowercased, ["takes", "take", "spend", "spent", "too long", "forever", "hours", "minutes"])
            ) {
            question = (
                "Quantify charting pain",
                "medium",
                "Ask: \"How many minutes per patient does documentation take today, and how many patients do you see on a normal day?\""
            )
        } else if Self.containsAny(lowercased, ["epic", "athena", "cerner", "modmed", "eclinicalworks", "ecw", "ehr", "emr", "copy paste", "integration"]) {
            question = (
                "Map the EHR workflow",
                "medium",
                "Ask: \"Where does the note need to land in your EHR, and what part of that handoff is most annoying today?\""
            )
        } else if Self.containsAny(lowercased, ["specialty", "template", "soap", "hpi", "assessment", "plan", "billing", "codes", "icd", "cpt"]) {
            question = (
                "Anchor the template",
                "medium",
                "Ask: \"What does a great note look like for your specialty, and what would make a generated note unusable for you?\""
            )
        } else if Self.containsAny(lowercased, ["provider", "providers", "doctors", "team", "clinic", "practice", "office manager", "staff"]) {
            question = (
                "Map team adoption",
                "medium",
                "Ask: \"Who would use this first, and whose approval or workflow would decide whether the rest of the team adopts it?\""
            )
        } else if Self.containsAny(lowercased, ["freed", "heidi", "nabla", "abridge", "dax", "dragon", "doximity", "suki", "scribe"]) {
            question = (
                "Compare current workflow",
                "medium",
                "Ask: \"What do you like about that workflow, and where do you still spend time cleaning things up?\""
            )
        } else if Self.containsAny(lowercased, ["trial", "test", "try it", "start", "get started", "card", "pricing"]) {
            question = (
                "Define trial success",
                "medium",
                "Ask: \"If we start the trial, what would you need to see in the first few visits to feel confident keeping it?\""
            )
        } else {
            question = nil
        }

        guard let question else { return nil }
        return SalesAssistAlert(
            kind: "discovery",
            objection: question.name,
            quote: String(text.suffix(260)),
            talkTrack: question.response,
            priority: question.priority,
            updatedAt: Date()
        )
    }

    private static func category(
        name: String,
        kind: String,
        priority: String,
        cues: [String],
        talkTrack: String
    ) -> SalesMomentCategory {
        SalesMomentCategory(
            name: name,
            kind: kind,
            priority: priority,
            cues: compile(cues),
            talkTrack: talkTrack
        )
    }

    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    private static func score(category: SalesMomentCategory, text: String, range: NSRange) -> Int {
        category.cues.reduce(0) { score, regex in
            score + (regex.firstMatch(in: text, options: [], range: range) == nil ? 0 : 1)
        }
    }

    private static func customTriggerPhrases(from raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
    }

    private static func normalizedLabel(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func normalizedPriority(_ raw: String) -> String {
        switch raw.lowercased() {
        case "high", "low":
            return raw.lowercased()
        default:
            return "medium"
        }
    }

    private static func priorityScore(_ priority: String) -> Int {
        switch priority.lowercased() {
        case "high": return 3
        case "low": return 1
        default: return 2
        }
    }

    private static func alertGroup(_ alert: SalesAssistAlert) -> String {
        let name = alert.objection.lowercased()
        if alert.kind == "objection", name.contains("partner") || name.contains("approval") {
            return "objection:approval"
        }
        if alert.kind == "pricing", name.contains("card") {
            return "pricing:card"
        }
        if alert.kind == "competitor" {
            return "competitor"
        }
        if alert.kind == "buying_signal" || alert.kind == "close" {
            return "close"
        }
        return "\(alert.kind):\(alert.objection.lowercased())"
    }

    private static func normalizedKind(_ raw: String) -> String {
        switch raw.lowercased() {
        case "buying_signal", "competitor", "discovery", "talk_ratio", "pricing", "close":
            return raw.lowercased()
        default:
            return "objection"
        }
    }
}

actor SalesAssistLLMClassifier {
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    private static let model = "gpt-5.4-mini"

    func classify(transcript: String, config: AppConfig) async -> SalesAssistAlert? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            let text = try await callWHAM(
                systemPrompt: Self.systemPrompt(config: config),
                userPrompt: Self.userPrompt(transcript: trimmed, config: config)
            )
            guard let result = try? Self.decodeResult(from: text), result.hasMoment else {
                return nil
            }
            guard let category = result.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !category.isEmpty,
                  let talkTrack = result.talkTrack?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !talkTrack.isEmpty
            else {
                return nil
            }

            let kind = Self.normalizedKind(result.momentType)
            guard config.salesAssistEnabledKinds.contains(kind) else { return nil }

            return SalesAssistAlert(
                kind: kind,
                objection: String(category.prefix(64)),
                quote: String((result.quote ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines).suffix(260)),
                talkTrack: String(talkTrack.prefix(360)),
                priority: Self.normalizedPriority(result.priority),
                updatedAt: Date()
            )
        } catch {
            fputs("[sales-assist] LLM classifier skipped: \(error)\n", stderr)
            return nil
        }
    }

    private func callWHAM(systemPrompt: String, userPrompt: String) async throws -> String {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        let body: [String: Any] = [
            "model": Self.model,
            "store": false,
            "stream": true,
            "instructions": systemPrompt,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": userPrompt],
                    ],
                ] as [String: Any],
            ],
        ]

        var request = URLRequest(url: Self.whamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let message = String(data: errorData, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpStatus)
            throw NSError(
                domain: "SalesAssistLLMClassifier",
                code: httpStatus,
                userInfo: [NSLocalizedDescriptionKey: String(message.prefix(800))]
            )
        }

        var fullText = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let outputText = json["output_text"] as? String, !outputText.isEmpty {
                fullText = outputText
            }
            if let type = json["type"] as? String,
               type == "response.output_text.delta",
               let delta = json["delta"] as? String {
                fullText += delta
            }
        }

        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func systemPrompt(config: AppConfig) -> String {
        let customCategories = config.salesAssistObjections
            .map { objection in
                let name = objection.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let priority = normalizedPriority(objection.priority)
                let triggers = objection.triggerPhrases.trimmingCharacters(in: .whitespacesAndNewlines)
                let guidance = objection.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
                return """
                - \(name.isEmpty ? "Custom objection" : name) [\(priority)]
                  Triggers: \(triggers.isEmpty ? "(none provided)" : triggers)
                  Guidance: \(guidance.isEmpty ? "(none provided)" : guidance)
                """
            }
            .joined(separator: "\n")
        let enabledKinds = config.salesAssistEnabledKinds
            .compactMap { SalesAssistLiveCue.kindLabels[$0] ?? $0 }
            .joined(separator: ", ")
        let customLiveCues = config.salesAssistLiveCues
            .map { cue in
                let name = cue.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let priority = normalizedPriority(cue.priority)
                let triggers = cue.triggerPhrases.trimmingCharacters(in: .whitespacesAndNewlines)
                let guidance = cue.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
                return """
                - \(name.isEmpty ? "Custom live cue" : name) [\(cue.kind), \(priority)]
                  Triggers: \(triggers.isEmpty ? "(none provided)" : triggers)
                  Guidance: \(guidance.isEmpty ? "(none provided)" : guidance)
                """
            }
            .joined(separator: "\n")

        return """
    You are a real-time sales objection classifier for Skriber sales calls.

    Detect the most useful live coaching moment for a sales rep. This can be an objection, a buying signal, a competitor/battlecard moment, a discovery gap, pricing friction, excessive rep talking, or a moment where the rep should close.

    Only return moments from these enabled popup types:
    \(enabledKinds.isEmpty ? "(none)" : enabledKinds)

    Built-in objection categories:
    - Partner approval
    - Decision hesitation
    - Send information soft exit
    - Card resistance
    - Too expensive
    - Already using competitor
    - No time
    - Trust or fit concern
    - Technical or security concern
    - Workflow concern
    - New objection

    Custom library categories:
    \(customCategories.isEmpty ? "- (none configured)" : customCategories)

    Custom live cue categories:
    \(customLiveCues.isEmpty ? "- (none configured)" : customLiveCues)

    Return only one JSON object with these fields:
    {
      "has_moment": true,
      "moment_type": "objection",
      "category": "Partner approval",
      "priority": "high",
      "quote": "short exact-ish quote from the transcript",
      "talk_track": "one concise thing the rep should say next"
    }

    moment_type must be one of: objection, buying_signal, competitor, discovery, talk_ratio, pricing, close.
    Use "has_moment": false when the text is ordinary conversation, filler, scheduling, or not enough evidence for useful coaching.
    Keep talk_track natural, specific, and under 45 words. Do not mention that you are an AI. Do not give multiple options.
    """
    }

    private static func userPrompt(transcript: String, config: AppConfig) -> String {
        let knowledgeBase = config.salesAssistKnowledgeBase.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Sales knowledge base:
        \(knowledgeBase.isEmpty ? "(none configured)" : knowledgeBase)

        Recent transcript:
        \(transcript)

        Classify the most important current live coaching moment, if any. Use the knowledge base to make the talk track specific.
        """
    }

    private struct ClassifierResult: Decodable {
        let hasMoment: Bool
        let momentType: String?
        let category: String?
        let priority: String?
        let quote: String?
        let talkTrack: String?

        enum CodingKeys: String, CodingKey {
            case hasMoment = "has_moment"
            case momentType = "moment_type"
            case category
            case priority
            case quote
            case talkTrack = "talk_track"
        }
    }

    private static func decodeResult(from text: String) throws -> ClassifierResult {
        let json = try extractJSONObject(from: text)
        return try JSONDecoder().decode(ClassifierResult.self, from: Data(json.utf8))
    }

    private static func extractJSONObject(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }

        let withoutFence = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if withoutFence.hasPrefix("{"), withoutFence.hasSuffix("}") {
            return withoutFence
        }

        guard let start = withoutFence.firstIndex(of: "{"),
              let end = withoutFence.lastIndex(of: "}"),
              start < end
        else {
            throw NSError(
                domain: "SalesAssistLLMClassifier",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Classifier response was not JSON"]
            )
        }
        return String(withoutFence[start...end])
    }

    private static func normalizedPriority(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "high":
            return "high"
        case "low":
            return "low"
        default:
            return "medium"
        }
    }

    private static func normalizedKind(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "buying_signal":
            return "buying_signal"
        case "competitor":
            return "competitor"
        case "discovery", "discovery_gap":
            return "discovery"
        case "talk_ratio", "talk_time":
            return "talk_ratio"
        case "pricing":
            return "pricing"
        case "close":
            return "close"
        default:
            return "objection"
        }
    }
}
