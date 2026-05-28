import AppKit
import SwiftUI
import MuesliCore
import UniformTypeIdentifiers

struct SalesDashboardView: View {
    private enum SalesAssistSection: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case preCall = "Pre-Call"
        case library = "Library"
        case overlay = "Live Overlay"
        case review = "Call Review"

        var id: String { rawValue }
    }

    let appState: AppState
    let controller: MuesliController
    @State private var selectedSection: SalesAssistSection = .overview
    @State private var selectedObjectionID: String?
    @State private var objectionSearchQuery = ""
    @State private var selectedLiveCueID: String?
    @State private var liveCueSearchQuery = ""
    @State private var selectedPreCallEventID: String?
    @State private var preCallCRMRecord: SalesCRMRecord?
    @State private var preCallCRMStatus: String?
    @State private var preCallCRMError: String?
    @State private var isLoadingPreCallCRM = false
    @State private var libraryMessage: String?
    @State private var libraryError: String?

    private var health: SalesCaddieHealthSnapshot {
        controller.salesCaddieHealthSnapshot()
    }

    private var reviewSummary: SalesCallReviewSummary {
        SalesCallReviewAnalyzer.summarize(meetings: appState.meetingRows)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                header
                sectionPicker
                sectionContent
            }
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .background(MuesliTheme.backgroundBase)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("Sales Assist")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Live coaching, sales knowledge, objections, battlecards, and post-call review.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            Spacer()
            actionButton("Connection settings", systemImage: "slider.horizontal.3") {
                appState.preferredSettingsPane = "sales"
                appState.selectedTab = .settings
            }
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $selectedSection) {
            ForEach(SalesAssistSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 620)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .overview:
            healthPanel
            testPanel
            learningQueuePanel
            reviewPreviewPanel
        case .preCall:
            preCallContent
        case .library:
            libraryEditorPanel
        case .overlay:
            liveOverlayPanel
            testPanel
        case .review:
            callReviewContent
        }
    }

    private var healthPanel: some View {
        panel("Shortcut Health") {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack(spacing: MuesliTheme.spacing12) {
                    statusTile("Mic", isGood: health.microphoneGranted)
                    statusTile("Input", isGood: health.inputMonitoringGranted)
                    statusTile("Access", isGood: health.accessibilityGranted)
                    statusTile("Screen", isGood: health.screenRecordingGranted)
                }

                Divider().background(MuesliTheme.surfaceBorder)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: MuesliTheme.spacing8) {
                    monitorRow("Dictation", enabled: health.dictationShortcutEnabled, running: health.dictationMonitorRunning)
                    monitorRow("Computer Use", enabled: health.computerUseShortcutEnabled, running: health.computerUseMonitorRunning)
                    monitorRow("Jessica", enabled: health.jessicaShortcutEnabled, running: health.jessicaMonitorRunning)
                    monitorRow("Meeting Recording", enabled: health.meetingShortcutEnabled, running: health.meetingMonitorRunning)
                }

                HStack(spacing: MuesliTheme.spacing8) {
                    readinessPill(health.allEnabledMonitorsRunning ? "Shortcut listeners running" : "Shortcut listener needs attention", good: health.allEnabledMonitorsRunning)
                    readinessPill(health.readyForLiveSalesAssist ? "Sales Assist ready" : "Sales Assist not ready", good: health.readyForLiveSalesAssist)
                    readinessPill("Agent: \(health.salesAgentProvider)", good: true)
                    readinessPill(health.supabaseSyncEnabled ? "Supabase on" : "Local only", good: health.supabaseSyncEnabled)
                }
            }
        }
    }

    private var testPanel: some View {
        panel("Test Controls") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: MuesliTheme.spacing12) {
                actionButton("Restart shortcuts", systemImage: "arrow.clockwise") {
                    controller.restartShortcutListeners()
                }
                actionButton("Test Jessica card", systemImage: "sparkles") {
                    controller.testJessicaResponseCard()
                }
                actionButton("Test meeting prompt", systemImage: "record.circle") {
                    controller.testMeetingRecordingPrompt()
                }
                actionButton("Test objection", systemImage: "exclamationmark.bubble") {
                    controller.testSalesAssistOverlay(kind: "objection")
                }
                actionButton("Test buying signal", systemImage: "hand.thumbsup") {
                    controller.testSalesAssistOverlay(kind: "buying_signal")
                }
                actionButton("Test battlecard", systemImage: "rectangle.stack") {
                    controller.testSalesAssistOverlay(kind: "competitor")
                }
            }
        }
    }

    private var learningQueuePanel: some View {
        panel("Post-Call Learning Queue") {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack {
                    Text("\(appState.config.salesAssistLearningSuggestions.count) pending suggestion\(appState.config.salesAssistLearningSuggestions.count == 1 ? "" : "s")")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Spacer()
                    actionButton("Analyze latest call", systemImage: "wand.and.stars") {
                        selectedSection = .library
                    }
                }

                if appState.config.salesAssistLearningSuggestions.isEmpty {
                    emptyLine("No pending call learnings.")
                } else {
                    ForEach(appState.config.salesAssistLearningSuggestions.prefix(4)) { suggestion in
                        learningRow(suggestion)
                    }
                }
            }
        }
    }

    private var reviewPreviewPanel: some View {
        panel("Call Review Dashboard") {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: MuesliTheme.spacing12) {
                    metricTile("\(reviewSummary.completedCalls)", "calls / 14 days")
                    metricTile("\(reviewSummary.totalMinutes)", "recorded minutes")
                    metricTile("\(reviewSummary.structuredNoteRate)%", "structured notes")
                    metricTile("\(reviewSummary.objectionMentions)", "objection mentions")
                }
                HStack {
                    Text("Competitors: \(reviewSummary.competitorMentions)  •  Buying signals: \(reviewSummary.buyingSignalMentions)")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                    Spacer()
                    actionButton("Open review", systemImage: "waveform.and.magnifyingglass") {
                        selectedSection = .review
                    }
                }
            }
        }
    }

    private var liveOverlayPanel: some View {
        panel("Live Overlay") {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                overlayControls
                Divider().background(MuesliTheme.surfaceBorder)
                HStack(spacing: MuesliTheme.spacing8) {
                    readinessPill(appState.config.salesAssistEnabled ? "Overlay on" : "Overlay off", good: appState.config.salesAssistEnabled)
                    readinessPill(appState.config.salesAssistAIEnabled ? "AI classifier on" : "Keyword mode", good: appState.config.salesAssistAIEnabled)
                    readinessPill("\(appState.config.salesAssistEnabledKinds.count) popup types", good: !appState.config.salesAssistEnabledKinds.isEmpty)
                    readinessPill(health.readyForLiveSalesAssist ? "Ready for calls" : "Needs permissions", good: health.readyForLiveSalesAssist)
                }
            }
        }
    }

    private var preCallContent: some View {
        let events = upcomingPreCallEvents
        let selectedEvent = selectedPreCallEvent(from: events)
        let provider = SalesCRMProvider(rawValue: appState.config.salesPreCallCRMProvider) ?? .none

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            panel("Briefing Setup") {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    HStack(spacing: MuesliTheme.spacing12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CRM provider")
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Picker("", selection: Binding(
                                get: { provider },
                                set: { newValue in
                                    controller.updateConfig { config in
                                        config.salesPreCallCRMProvider = newValue.rawValue
                                    }
                                }
                            )) {
                                ForEach(SalesCRMProvider.allCases) { crmProvider in
                                    Text(crmProvider.label).tag(crmProvider)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connection label")
                                .font(MuesliTheme.captionMedium())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            PastableTextField(
                                text: appState.config.salesPreCallCRMConnectionLabel,
                                placeholder: "Production HighLevel, HubSpot sandbox, Salesforce org..."
                            ) { value in
                                controller.updateConfig { $0.salesPreCallCRMConnectionLabel = value }
                            }
                            .frame(height: 28)
                        }
                    }

                    if provider == .highLevel {
                        highLevelConnectionFields
                    } else if provider == .hubSpot || provider == .salesforce {
                        Text("\(provider.label) is available in the briefing schema, but live fetching is not connected yet.")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Divider().background(MuesliTheme.surfaceBorder)

                    Text("Briefing modules")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(appState.config.salesPreCallBriefingModules.sorted { $0.sortOrder < $1.sortOrder }) { module in
                            preCallModuleEditorRow(module)
                        }
                    }

                    HStack(spacing: MuesliTheme.spacing8) {
                        actionButton("Add custom module", systemImage: "plus") {
                            controller.updateConfig { config in
                                let nextOrder = (config.salesPreCallBriefingModules.map(\.sortOrder).max() ?? 60) + 10
                                config.salesPreCallBriefingModules.append(
                                    SalesPreCallBriefingModule(
                                        id: UUID().uuidString,
                                        kind: .custom,
                                        title: "Custom Briefing Block",
                                        instructions: "Describe what this pre-call block should show.",
                                        isEnabled: true,
                                        sortOrder: nextOrder
                                    )
                                )
                            }
                        }
                        actionButton("Reset defaults", systemImage: "arrow.counterclockwise") {
                            controller.updateConfig {
                                $0.salesPreCallBriefingModules = SalesPreCallBriefingModule.defaultModules
                            }
                        }
                    }
                }
            }

            panel("Upcoming Calls") {
                if events.isEmpty {
                    emptyLine("No upcoming calendar calls found.")
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(events) { event in
                            preCallEventRow(event, isSelected: selectedEvent?.id == event.id)
                        }
                    }
                }
            }

            panel("Pre-Call Briefing") {
                if let selectedEvent {
                    preCallBriefingView(
                        SalesPreCallBriefingBuilder.build(
                            event: selectedEvent,
                            meetings: appState.meetingRows,
                            modules: appState.config.salesPreCallBriefingModules,
                            crmProvider: provider,
                            crmRecord: preCallCRMRecord
                        )
                    )
                } else {
                    emptyLine("Select an upcoming call to preview the briefing.")
                }
            }
        }
        .task(id: selectedEvent?.id ?? "no-event") {
            await loadPreCallCRMIfNeeded(event: selectedEvent, provider: provider)
        }
        .onChange(of: appState.config.salesPreCallCRMProvider) { _, _ in
            clearPreCallCRMState()
        }
        .onChange(of: appState.config.salesPreCallHighLevelToken) { _, _ in
            clearPreCallCRMState()
        }
        .onChange(of: appState.config.salesPreCallHighLevelLocationID) { _, _ in
            clearPreCallCRMState()
        }
    }

    private var callReviewContent: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            panel("Last 14 Days") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: MuesliTheme.spacing12) {
                    metricTile("\(reviewSummary.completedCalls)", "completed calls")
                    metricTile("\(reviewSummary.averageMinutes)", "avg minutes")
                    metricTile("\(reviewSummary.totalWords)", "transcript words")
                    metricTile("\(reviewSummary.rawTranscriptFallbacks)", "raw-note fallbacks")
                    metricTile("\(reviewSummary.objectionMentions)", "objection mentions")
                    metricTile("\(reviewSummary.competitorMentions)", "competitor mentions")
                    metricTile("\(reviewSummary.buyingSignalMentions)", "buying signals")
                    metricTile("\(reviewSummary.averageSalesScore)", "avg sales score")
                }
            }

            panel("Sales Scorecards") {
                if reviewSummary.scorecards.isEmpty {
                    emptyLine("No scorecards available yet.")
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(reviewSummary.scorecards) { scorecard in
                            salesScorecardRow(scorecard, controller: controller)
                        }
                    }
                }
            }

            panel("Action Items") {
                if reviewSummary.actionItems.isEmpty {
                    emptyLine("No action items found in recent calls.")
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(reviewSummary.actionItems) { item in
                            callActionItemRow(item, controller: controller)
                        }
                    }
                }
            }

            panel("Call Insights") {
                if reviewSummary.callInsights.isEmpty {
                    emptyLine("No call insights found in recent calls.")
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(reviewSummary.callInsights) { insight in
                            callInsightRow(insight, controller: controller)
                        }
                    }
                }
            }

            panel("Follow-Up Drafts") {
                if reviewSummary.followUpDrafts.isEmpty {
                    emptyLine("No follow-up drafts available yet.")
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(reviewSummary.followUpDrafts) { draft in
                            followUpDraftRow(draft, controller: controller)
                        }
                    }
                }
            }

            panel("CRM Notes") {
                if reviewSummary.crmNoteDrafts.isEmpty {
                    emptyLine("No CRM note drafts available yet.")
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(reviewSummary.crmNoteDrafts) { draft in
                            crmNoteDraftRow(draft, controller: controller)
                        }
                    }
                }
            }

            panel("Manager Coaching") {
                if reviewSummary.coachingThemes.isEmpty {
                    emptyLine("No coaching themes found yet.")
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(reviewSummary.coachingThemes) { theme in
                            coachingThemeRow(theme)
                        }
                    }
                }
            }

            panel("Customer Memory") {
                if reviewSummary.customerMemories.isEmpty {
                    emptyLine("No customer memory available yet.")
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(reviewSummary.customerMemories) { memory in
                            customerMemoryRow(memory, controller: controller)
                        }
                    }
                }
            }

            panel("Recent Calls") {
                if reviewSummary.recentCalls.isEmpty {
                    emptyLine("No completed calls in the last 14 days.")
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(reviewSummary.recentCalls) { meeting in
                            Button {
                                controller.showMeetingDocument(id: meeting.id)
                            } label: {
                                HStack(spacing: MuesliTheme.spacing12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(meeting.title)
                                            .font(MuesliTheme.headline())
                                            .foregroundStyle(MuesliTheme.textPrimary)
                                            .lineLimit(1)
                                        Text("\(Int(meeting.durationSeconds / 60)) min • \(meeting.wordCount) words • \(meeting.notesState.rawValue.replacingOccurrences(of: "_", with: " "))")
                                            .font(MuesliTheme.caption())
                                            .foregroundStyle(MuesliTheme.textTertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                }
                                .padding(MuesliTheme.spacing12)
                                .background(MuesliTheme.surfacePrimary.opacity(0.45))
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var filteredObjections: [SalesAssistObjection] {
        let query = objectionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return appState.config.salesAssistObjections }
        return appState.config.salesAssistObjections.filter { objection in
            objection.name.lowercased().contains(query)
                || objection.triggerPhrases.lowercased().contains(query)
                || objection.guidance.lowercased().contains(query)
        }
    }

    private var highLevelConnectionFields: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HighLevel Location ID")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    PastableTextField(
                        text: appState.config.salesPreCallHighLevelLocationID,
                        placeholder: "Sub-account / location ID"
                    ) { value in
                        controller.updateConfig { $0.salesPreCallHighLevelLocationID = value }
                    }
                    .frame(height: 28)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("API base URL")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    PastableTextField(
                        text: appState.config.salesPreCallHighLevelBaseURL,
                        placeholder: "https://services.leadconnectorhq.com"
                    ) { value in
                        controller.updateConfig { $0.salesPreCallHighLevelBaseURL = value }
                    }
                    .frame(height: 28)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Private integration token")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.textPrimary)
                PastableSecureField(
                    text: appState.config.salesPreCallHighLevelToken,
                    placeholder: "Bearer token / PIT"
                ) { value in
                    controller.updateConfig { $0.salesPreCallHighLevelToken = value }
                }
                .frame(height: 28)
            }

            HStack(spacing: MuesliTheme.spacing8) {
                readinessPill(highLevelConfig.isConfigured ? "HighLevel configured" : "Missing HighLevel credentials", good: highLevelConfig.isConfigured)
                if let preCallCRMStatus {
                    readinessPill(preCallCRMStatus, good: preCallCRMRecord != nil)
                }
                if isLoadingPreCallCRM {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                actionButton("Test HighLevel", systemImage: "checkmark.circle") {
                    Task { await testHighLevelConnection() }
                }
                .disabled(isLoadingPreCallCRM || !highLevelConfig.isConfigured)
            }

            if let preCallCRMError {
                Text(preCallCRMError)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.transcribing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var highLevelConfig: HighLevelCRMConfig {
        HighLevelCRMConfig(
            baseURL: appState.config.salesPreCallHighLevelBaseURL,
            token: appState.config.salesPreCallHighLevelToken,
            locationID: appState.config.salesPreCallHighLevelLocationID
        )
    }

    private var upcomingPreCallEvents: [UnifiedCalendarEvent] {
        appState.upcomingCalendarEvents
            .filter { !$0.isAllDay && !appState.hiddenCalendarEventIDs.contains($0.id) && $0.startDate >= Date().addingTimeInterval(-900) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { $0 }
    }

    private func selectedPreCallEvent(from events: [UnifiedCalendarEvent]) -> UnifiedCalendarEvent? {
        if let selectedPreCallEventID,
           let event = events.first(where: { $0.id == selectedPreCallEventID }) {
            return event
        }
        return events.first
    }

    private func loadPreCallCRMIfNeeded(event: UnifiedCalendarEvent?, provider: SalesCRMProvider) async {
        guard provider == .highLevel, let event, highLevelConfig.isConfigured else {
            if provider != .highLevel { clearPreCallCRMState() }
            return
        }
        await fetchPreCallCRM(event: event)
    }

    private func fetchPreCallCRM(event: UnifiedCalendarEvent) async {
        isLoadingPreCallCRM = true
        preCallCRMError = nil
        preCallCRMStatus = "Searching HighLevel"
        do {
            let record = try await HighLevelCRMClient.fetchPreCallRecord(for: event, config: highLevelConfig)
            preCallCRMRecord = record
            preCallCRMStatus = "HighLevel matched"
            preCallCRMError = nil
        } catch {
            preCallCRMRecord = nil
            preCallCRMStatus = "No HighLevel match"
            preCallCRMError = error.localizedDescription
        }
        isLoadingPreCallCRM = false
    }

    private func testHighLevelConnection() async {
        isLoadingPreCallCRM = true
        preCallCRMError = nil
        preCallCRMStatus = "Testing HighLevel"
        do {
            try await HighLevelCRMClient.testConnection(config: highLevelConfig)
            preCallCRMStatus = "HighLevel connected"
        } catch {
            preCallCRMStatus = "HighLevel failed"
            preCallCRMError = error.localizedDescription
        }
        isLoadingPreCallCRM = false
    }

    private func clearPreCallCRMState() {
        preCallCRMRecord = nil
        preCallCRMStatus = nil
        preCallCRMError = nil
    }

    private func preCallModuleEditorRow(_ module: SalesPreCallBriefingModule) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing8) {
                Toggle("", isOn: Binding(
                    get: { module.isEnabled },
                    set: { value in
                        updatePreCallModule(module.id) { $0.isEnabled = value }
                    }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()

                PastableTextField(text: module.title, placeholder: "Module title") { value in
                    updatePreCallModule(module.id) { $0.title = value }
                }
                .frame(height: 28)

                readinessPill(module.kind.rawValue, good: module.isEnabled)
            }
            PastableTextField(text: module.instructions, placeholder: "What should this module show?") { value in
                updatePreCallModule(module.id) { $0.instructions = value }
            }
            .frame(height: 28)
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private func preCallEventRow(_ event: UnifiedCalendarEvent, isSelected: Bool) -> some View {
        Button {
            selectedPreCallEventID = event.id
        } label: {
            HStack(spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    Text(preCallDateFormatter.string(from: event.startDate))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer()
                readinessPill(event.meetingURL == nil ? "calendar" : "meeting link", good: event.meetingURL != nil)
            }
            .padding(MuesliTheme.spacing12)
            .background(isSelected ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isSelected ? MuesliTheme.accent.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func preCallBriefingView(_ briefing: SalesPreCallBriefing) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing8) {
                Text(briefing.eventTitle)
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                Spacer()
                readinessPill(briefing.crmStatus, good: briefing.crmProvider != .none)
            }
            Text(preCallDateFormatter.string(from: briefing.startsAt))
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)

            ForEach(briefing.sections) { section in
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    HStack {
                        Text(section.title)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Spacer()
                        Text(section.source)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    Text(section.body)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(section.bullets, id: \.self) { bullet in
                            HStack(alignment: .top, spacing: MuesliTheme.spacing8) {
                                Text("-")
                                    .font(MuesliTheme.caption())
                                    .foregroundStyle(MuesliTheme.accent)
                                Text(bullet)
                                    .font(MuesliTheme.caption())
                                    .foregroundStyle(MuesliTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(MuesliTheme.spacing12)
                .background(MuesliTheme.surfacePrimary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
        }
    }

    private var preCallDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private func updatePreCallModule(_ id: String, mutate: @escaping (inout SalesPreCallBriefingModule) -> Void) {
        controller.updateConfig { config in
            guard let index = config.salesPreCallBriefingModules.firstIndex(where: { $0.id == id }) else { return }
            mutate(&config.salesPreCallBriefingModules[index])
            config.salesPreCallBriefingModules = AppConfig.mergedPreCallModules(config.salesPreCallBriefingModules)
        }
    }

    private var selectedObjection: SalesAssistObjection? {
        if let selectedObjectionID,
           let objection = appState.config.salesAssistObjections.first(where: { $0.id == selectedObjectionID }) {
            return objection
        }
        return filteredObjections.first ?? appState.config.salesAssistObjections.first
    }

    private var filteredLiveCues: [SalesAssistLiveCue] {
        let query = liveCueSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return appState.config.salesAssistLiveCues }
        return appState.config.salesAssistLiveCues.filter { cue in
            cue.name.lowercased().contains(query)
                || cue.kind.lowercased().contains(query)
                || cue.triggerPhrases.lowercased().contains(query)
                || cue.guidance.lowercased().contains(query)
        }
    }

    private var selectedLiveCue: SalesAssistLiveCue? {
        if let selectedLiveCueID,
           let cue = appState.config.salesAssistLiveCues.first(where: { $0.id == selectedLiveCueID }) {
            return cue
        }
        return filteredLiveCues.first ?? appState.config.salesAssistLiveCues.first
    }

    private var libraryEditorPanel: some View {
        panel("Sales Library") {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    HStack {
                        Text("Knowledge Base")
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Spacer()
                        actionButton("Replace", systemImage: "doc.badge.gearshape") {
                            importKnowledgeBase(append: false)
                        }
                        .frame(width: 118)
                        actionButton("Append", systemImage: "doc.badge.plus") {
                            importKnowledgeBase(append: true)
                        }
                        .frame(width: 108)
                    }
                    MultilineTextEditor(
                        text: appState.config.salesAssistKnowledgeBase,
                        placeholder: "Product, process, pricing, qualification notes, talk-track rules, and anything Jessica should know when coaching a rep.",
                        minHeight: 150
                    ) { value in
                        controller.updateConfig { $0.salesAssistKnowledgeBase = value }
                    }
                    .frame(minHeight: 150)
                }

                if let libraryMessage {
                    Text(libraryMessage)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.success)
                }
                if let libraryError {
                    Text(libraryError)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.recording)
                }

                Divider().background(MuesliTheme.surfaceBorder)

                HStack(alignment: .top, spacing: MuesliTheme.spacing16) {
                    objectionLibrary
                    liveCueLibrary
                }
            }
        }
        .onAppear {
            ensureSelectedObjection()
            ensureSelectedLiveCue()
        }
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Overlay")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Choose every popup type that should be allowed to run during a call.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { appState.config.salesAssistEnabled },
                    set: { value in controller.updateConfig { $0.salesAssistEnabled = value } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                Toggle("AI", isOn: Binding(
                    get: { appState.config.salesAssistAIEnabled },
                    set: { value in controller.updateConfig { $0.salesAssistAIEnabled = value } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: MuesliTheme.spacing8)], spacing: MuesliTheme.spacing8) {
                ForEach(SalesAssistLiveCue.supportedKinds, id: \.self) { kind in
                    overlayKindToggle(kind)
                }
            }
        }
    }

    private var objectionLibrary: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack {
                Text("Objections")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("\(filteredObjections.count)/\(appState.config.salesAssistObjections.count)")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Spacer()
                actionButton("Add", systemImage: "plus") {
                    controller.updateConfig { config in
                        let objection = SalesAssistObjection()
                        config.salesAssistObjections.append(objection)
                        selectedObjectionID = objection.id
                    }
                }
                .frame(width: 82)
            }

            PastableTextField(text: objectionSearchQuery, placeholder: "Search objections") { value in
                objectionSearchQuery = value
                selectedObjectionID = filteredObjections.first?.id
            }
            .frame(height: 28)

            libraryPicker(
                items: filteredObjections,
                selectedID: selectedObjection?.id,
                title: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled objection" : $0.name },
                subtitle: { $0.triggerPhrases },
                onSelect: { selectedObjectionID = $0.id }
            )

            if let selectedObjection {
                objectionEditor(selectedObjection)
            } else {
                emptyLine("No objection selected.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: appState.config.salesAssistObjections.map(\.id)) { _, _ in
            ensureSelectedObjection()
        }
    }

    private var liveCueLibrary: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack {
                Text("Popups")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("\(filteredLiveCues.count)/\(appState.config.salesAssistLiveCues.count)")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Spacer()
                actionButton("Add", systemImage: "plus") {
                    controller.updateConfig { config in
                        let cue = SalesAssistLiveCue()
                        config.salesAssistLiveCues.append(cue)
                        selectedLiveCueID = cue.id
                    }
                }
                .frame(width: 82)
            }

            PastableTextField(text: liveCueSearchQuery, placeholder: "Search buying signals, battlecards, discovery") { value in
                liveCueSearchQuery = value
                selectedLiveCueID = filteredLiveCues.first?.id
            }
            .frame(height: 28)

            libraryPicker(
                items: filteredLiveCues,
                selectedID: selectedLiveCue?.id,
                title: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled popup" : $0.name },
                subtitle: { SalesAssistLiveCue.kindLabels[$0.kind] ?? $0.kind },
                onSelect: { selectedLiveCueID = $0.id }
            )

            if let selectedLiveCue {
                liveCueEditor(selectedLiveCue)
            } else {
                emptyLine("No popup selected.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: appState.config.salesAssistLiveCues.map(\.id)) { _, _ in
            ensureSelectedLiveCue()
        }
    }

    private func learningRow(_ suggestion: SalesAssistLearningSuggestion) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                readinessPill(suggestion.kind == .objection ? "Objection" : "KB", good: true)
                Text(suggestion.title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Spacer()
            }
            Text(suggestion.content)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(3)
            HStack {
                Spacer()
                actionButton("Accept", systemImage: "checkmark") {
                    acceptLearningSuggestion(suggestion)
                }
                actionButton("Dismiss", systemImage: "xmark") {
                    dismissLearningSuggestion(suggestion)
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private func acceptLearningSuggestion(_ suggestion: SalesAssistLearningSuggestion) {
        controller.updateConfig { config in
            switch suggestion.kind {
            case .knowledgeBase:
                let note = "\n\n## \(suggestion.title)\n\(suggestion.content)"
                config.salesAssistKnowledgeBase += note
            case .objection:
                if let objection = suggestion.objection {
                    config.salesAssistObjections.append(objection)
                }
            }
            config.salesAssistLearningSuggestions.removeAll { $0.id == suggestion.id }
        }
    }

    private func dismissLearningSuggestion(_ suggestion: SalesAssistLearningSuggestion) {
        controller.updateConfig { config in
            config.salesAssistLearningSuggestions.removeAll { $0.id == suggestion.id }
        }
    }

    private func overlayKindToggle(_ kind: String) -> some View {
        let isEnabled = appState.config.salesAssistEnabledKinds.contains(kind)
        return Button {
            controller.updateConfig { config in
                var enabled = Set(config.salesAssistEnabledKinds)
                if isEnabled {
                    enabled.remove(kind)
                } else {
                    enabled.insert(kind)
                }
                config.salesAssistEnabledKinds = SalesAssistLiveCue.supportedKinds.filter { enabled.contains($0) }
            }
        } label: {
            HStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isEnabled ? MuesliTheme.accent : MuesliTheme.textTertiary)
                Text(SalesAssistLiveCue.kindLabels[kind] ?? kind)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isEnabled ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(isEnabled ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func libraryPicker<Item: Identifiable>(
        items: [Item],
        selectedID: Item.ID?,
        title: @escaping (Item) -> String,
        subtitle: @escaping (Item) -> String,
        onSelect: @escaping (Item) -> Void
    ) -> some View where Item.ID: Equatable {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    let isSelected = item.id == selectedID
                    Button {
                        onSelect(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(item))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MuesliTheme.textPrimary)
                                .lineLimit(1)
                            Text(shortLibrarySubtitle(subtitle(item)))
                                .font(.system(size: 10))
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .background(isSelected ? MuesliTheme.accentSubtle : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .strokeBorder(isSelected ? MuesliTheme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(height: 165)
        .background(MuesliTheme.surfacePrimary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func objectionEditor(_ objection: SalesAssistObjection) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing8) {
                PastableTextField(text: objection.name, placeholder: "Objection name") { value in
                    updateObjection(objection.id) { $0.name = value }
                }
                .frame(height: 28)
                priorityMenu(selection: objection.priority) { value in
                    updateObjection(objection.id) { $0.priority = value }
                }
                .frame(width: 110)
                trashButton {
                    controller.updateConfig { config in
                        config.salesAssistObjections.removeAll { $0.id == objection.id }
                        selectedObjectionID = config.salesAssistObjections.first?.id
                    }
                }
            }
            labeledEditor("Trigger phrases", text: objection.triggerPhrases, placeholder: "One per line, or comma separated.") { value in
                updateObjection(objection.id) { $0.triggerPhrases = value }
            }
            labeledEditor("Handling guidance", text: objection.guidance, placeholder: "What should the rep say or ask next?") { value in
                updateObjection(objection.id) { $0.guidance = value }
            }
        }
    }

    private func liveCueEditor(_ cue: SalesAssistLiveCue) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing8) {
                PastableTextField(text: cue.name, placeholder: "Popup name") { value in
                    updateLiveCue(cue.id) { $0.name = value }
                }
                .frame(height: 28)
                Picker("", selection: Binding(
                    get: { cue.kind },
                    set: { value in updateLiveCue(cue.id) { $0.kind = value } }
                )) {
                    ForEach(SalesAssistLiveCue.supportedKinds.filter { $0 != "objection" }, id: \.self) { kind in
                        Text(SalesAssistLiveCue.kindLabels[kind] ?? kind).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                priorityMenu(selection: cue.priority) { value in
                    updateLiveCue(cue.id) { $0.priority = value }
                }
                .frame(width: 110)
                trashButton {
                    controller.updateConfig { config in
                        config.salesAssistLiveCues.removeAll { $0.id == cue.id }
                        selectedLiveCueID = config.salesAssistLiveCues.first?.id
                    }
                }
            }
            labeledEditor("Trigger phrases", text: cue.triggerPhrases, placeholder: "One per line. Example: how do we get started, using Freed, notes take forever") { value in
                updateLiveCue(cue.id) { $0.triggerPhrases = value }
            }
            labeledEditor("Overlay guidance", text: cue.guidance, placeholder: "What should the rep say, ask, or do when this pops up?") { value in
                updateLiveCue(cue.id) { $0.guidance = value }
            }
        }
    }

    private func labeledEditor(_ label: String, text: String, placeholder: String, onChange: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            MultilineTextEditor(text: text, placeholder: placeholder, minHeight: 64, onChange: onChange)
                .frame(minHeight: 64)
        }
    }

    private func priorityMenu(selection: String, onChange: @escaping (String) -> Void) -> some View {
        Picker("", selection: Binding(
            get: { selection.lowercased() },
            set: { onChange($0) }
        )) {
            Text("High").tag("high")
            Text("Medium").tag("medium")
            Text("Low").tag("low")
        }
        .labelsHidden()
    }

    private func trashButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.recording)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }

    private func updateObjection(_ id: String, mutate: @escaping (inout SalesAssistObjection) -> Void) {
        controller.updateConfig { config in
            guard let index = config.salesAssistObjections.firstIndex(where: { $0.id == id }) else { return }
            mutate(&config.salesAssistObjections[index])
        }
    }

    private func updateLiveCue(_ id: String, mutate: @escaping (inout SalesAssistLiveCue) -> Void) {
        controller.updateConfig { config in
            guard let index = config.salesAssistLiveCues.firstIndex(where: { $0.id == id }) else { return }
            mutate(&config.salesAssistLiveCues[index])
        }
    }

    private func ensureSelectedObjection() {
        if let selectedObjectionID,
           appState.config.salesAssistObjections.contains(where: { $0.id == selectedObjectionID }) {
            return
        }
        selectedObjectionID = filteredObjections.first?.id ?? appState.config.salesAssistObjections.first?.id
    }

    private func ensureSelectedLiveCue() {
        if let selectedLiveCueID,
           appState.config.salesAssistLiveCues.contains(where: { $0.id == selectedLiveCueID }) {
            return
        }
        selectedLiveCueID = filteredLiveCues.first?.id ?? appState.config.salesAssistLiveCues.first?.id
    }

    private func importKnowledgeBase(append: Bool) {
        libraryMessage = nil
        libraryError = nil
        let panel = NSOpenPanel()
        panel.title = append ? "Append Knowledge Base File" : "Replace Knowledge Base From File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .plainText,
            .text,
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
        ].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try SalesAssistLibraryImport.text(from: url)
            guard !imported.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SalesAssistImportError.unreadableFile
            }
            controller.updateConfig { config in
                if append, !config.salesAssistKnowledgeBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    config.salesAssistKnowledgeBase += "\n\n" + imported
                } else {
                    config.salesAssistKnowledgeBase = imported
                }
            }
            libraryMessage = append ? "Knowledge base appended." : "Knowledge base replaced."
        } catch {
            libraryError = error.localizedDescription
        }
    }

    private func shortLibrarySubtitle(_ text: String) -> String {
        text.components(separatedBy: CharacterSet(charactersIn: "\n,;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: ", ")
    }
}

struct SalesCallReviewView: View {
    let appState: AppState
    let controller: MuesliController

    private var summary: SalesCallReviewSummary {
        SalesCallReviewAnalyzer.summarize(meetings: appState.meetingRows)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Call Review")
                            .font(MuesliTheme.title1())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text("A lightweight manager view of recent recorded sales calls and coaching signals.")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textSecondary)
                    }
                    Spacer()
                    actionButton("Back to Sales", systemImage: "chart.line.uptrend.xyaxis") {
                        appState.selectedTab = .sales
                    }
                }

                panel("Last 14 Days") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: MuesliTheme.spacing12) {
                        metricTile("\(summary.completedCalls)", "completed calls")
                        metricTile("\(summary.averageMinutes)", "avg minutes")
                        metricTile("\(summary.totalWords)", "transcript words")
                        metricTile("\(summary.rawTranscriptFallbacks)", "raw-note fallbacks")
                        metricTile("\(summary.objectionMentions)", "objection mentions")
                        metricTile("\(summary.competitorMentions)", "competitor mentions")
                        metricTile("\(summary.buyingSignalMentions)", "buying signals")
                        metricTile("\(summary.averageSalesScore)", "avg sales score")
                    }
                }

                panel("Sales Scorecards") {
                    if summary.scorecards.isEmpty {
                        emptyLine("No scorecards available yet.")
                    } else {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                            ForEach(summary.scorecards) { scorecard in
                                salesScorecardRow(scorecard, controller: controller)
                            }
                        }
                    }
                }

                panel("Action Items") {
                    if summary.actionItems.isEmpty {
                        emptyLine("No action items found in recent calls.")
                    } else {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                            ForEach(summary.actionItems) { item in
                                callActionItemRow(item, controller: controller)
                            }
                        }
                    }
                }

                panel("Call Insights") {
                    if summary.callInsights.isEmpty {
                        emptyLine("No call insights found in recent calls.")
                    } else {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                            ForEach(summary.callInsights) { insight in
                                callInsightRow(insight, controller: controller)
                            }
                        }
                    }
                }

                panel("Follow-Up Drafts") {
                    if summary.followUpDrafts.isEmpty {
                        emptyLine("No follow-up drafts available yet.")
                    } else {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                            ForEach(summary.followUpDrafts) { draft in
                                followUpDraftRow(draft, controller: controller)
                            }
                        }
                    }
                }

                panel("CRM Notes") {
                    if summary.crmNoteDrafts.isEmpty {
                        emptyLine("No CRM note drafts available yet.")
                    } else {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                            ForEach(summary.crmNoteDrafts) { draft in
                                crmNoteDraftRow(draft, controller: controller)
                            }
                        }
                    }
                }

                panel("Manager Coaching") {
                    if summary.coachingThemes.isEmpty {
                        emptyLine("No coaching themes found yet.")
                    } else {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                            ForEach(summary.coachingThemes) { theme in
                                coachingThemeRow(theme)
                            }
                        }
                    }
                }

                panel("Customer Memory") {
                    if summary.customerMemories.isEmpty {
                        emptyLine("No customer memory available yet.")
                    } else {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                            ForEach(summary.customerMemories) { memory in
                                customerMemoryRow(memory, controller: controller)
                            }
                        }
                    }
                }

                panel("Recent Calls") {
                    if summary.recentCalls.isEmpty {
                        emptyLine("No completed calls in the last 14 days.")
                    } else {
                        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                            ForEach(summary.recentCalls) { meeting in
                                Button {
                                    controller.showMeetingDocument(id: meeting.id)
                                } label: {
                                    HStack(spacing: MuesliTheme.spacing12) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(meeting.title)
                                                .font(MuesliTheme.headline())
                                                .foregroundStyle(MuesliTheme.textPrimary)
                                                .lineLimit(1)
                                            Text("\(Int(meeting.durationSeconds / 60)) min • \(meeting.wordCount) words • \(meeting.notesState.rawValue.replacingOccurrences(of: "_", with: " "))")
                                                .font(MuesliTheme.caption())
                                                .foregroundStyle(MuesliTheme.textTertiary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(MuesliTheme.textTertiary)
                                    }
                                    .padding(MuesliTheme.spacing12)
                                    .background(MuesliTheme.surfacePrimary.opacity(0.45))
                                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .background(MuesliTheme.backgroundBase)
    }
}

private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MuesliTheme.textTertiary)
            .textCase(.uppercase)
        content()
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
    }
}

private func statusTile(_ label: String, isGood: Bool) -> some View {
    HStack(spacing: MuesliTheme.spacing8) {
        Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(isGood ? MuesliTheme.success : MuesliTheme.transcribing)
        Text(label)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.textPrimary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, MuesliTheme.spacing12)
    .padding(.vertical, MuesliTheme.spacing8)
    .background(MuesliTheme.surfacePrimary.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
}

private func monitorRow(_ label: String, enabled: Bool, running: Bool) -> some View {
    HStack {
        Text(label)
            .font(MuesliTheme.body())
            .foregroundStyle(MuesliTheme.textPrimary)
        Spacer()
        readinessPill(!enabled ? "Off" : running ? "Running" : "Stopped", good: !enabled || running)
    }
    .padding(.vertical, 2)
}

private func readinessPill(_ label: String, good: Bool) -> some View {
    Text(label)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(good ? MuesliTheme.success : MuesliTheme.transcribing)
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 4)
        .background((good ? MuesliTheme.success : MuesliTheme.transcribing).opacity(0.12))
        .clipShape(Capsule())
}

private func metricTile(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(value)
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(MuesliTheme.textPrimary)
        Text(label)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textTertiary)
            .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(MuesliTheme.spacing12)
    .background(MuesliTheme.surfacePrimary.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
}

private func salesScorecardRow(_ scorecard: SalesCallScorecard, controller: MuesliController) -> some View {
    Button {
        controller.showMeetingDocument(id: scorecard.meetingID)
    } label: {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            VStack(spacing: 2) {
                Text("\(scorecard.score)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(scoreColor(scorecard.score))
                Text("score")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .textCase(.uppercase)
            }
            .frame(width: 58, height: 52)
            .background(scoreColor(scorecard.score).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

            VStack(alignment: .leading, spacing: 7) {
                Text(scorecard.meetingTitle)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                compactList("Strengths", scorecard.strengths, color: MuesliTheme.success)
                compactList("Coach", scorecard.coachingGaps, color: MuesliTheme.accent)
                compactList("Risks", scorecard.riskFlags, color: MuesliTheme.transcribing)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }
    .buttonStyle(.plain)
}

private func followUpDraftRow(_ draft: SalesCallFollowUpDraft, controller: MuesliController) -> some View {
    HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
        Image(systemName: "paperplane.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(MuesliTheme.accent)
            .frame(width: 24, height: 24)
            .background(MuesliTheme.accent.opacity(0.12))
            .clipShape(Circle())
        VStack(alignment: .leading, spacing: 5) {
            Text(draft.subject)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
            Text(draft.body)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(4)
            Text(draft.meetingTitle)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .lineLimit(1)
        }
        Spacer()
        smallIconButton("doc.on.doc") {
            copyToClipboard("Subject: \(draft.subject)\n\n\(draft.body)")
        }
        smallIconButton("chevron.right") {
            Task { @MainActor in
                controller.showMeetingDocument(id: draft.meetingID)
            }
        }
    }
    .padding(MuesliTheme.spacing12)
    .background(MuesliTheme.surfacePrimary.opacity(0.45))
    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
}

private func crmNoteDraftRow(_ draft: SalesCallCRMNoteDraft, controller: MuesliController) -> some View {
    HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
        Image(systemName: "square.text.square.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(MuesliTheme.accent)
            .frame(width: 24, height: 24)
            .background(MuesliTheme.accent.opacity(0.12))
            .clipShape(Circle())
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: MuesliTheme.spacing8) {
                Text(draft.outcome)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                readinessPill("CRM draft", good: true)
            }
            Text(draft.note)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(5)
            Text(draft.meetingTitle)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .lineLimit(1)
        }
        Spacer()
        smallIconButton("doc.on.doc") {
            copyToClipboard(draft.note)
        }
        smallIconButton("chevron.right") {
            Task { @MainActor in
                controller.showMeetingDocument(id: draft.meetingID)
            }
        }
    }
    .padding(MuesliTheme.spacing12)
    .background(MuesliTheme.surfacePrimary.opacity(0.45))
    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
}

private func coachingThemeRow(_ theme: SalesCoachingTheme) -> some View {
    HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
        Text("\(theme.count)")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(MuesliTheme.accent)
            .frame(width: 36, height: 36)
            .background(MuesliTheme.accent.opacity(0.12))
            .clipShape(Circle())
        VStack(alignment: .leading, spacing: 5) {
            Text(theme.title)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(1)
            Text(theme.guidance)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineLimit(2)
            Text("Example: \(theme.exampleMeetingTitle)")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .lineLimit(1)
        }
        Spacer()
    }
    .padding(MuesliTheme.spacing12)
    .background(MuesliTheme.surfacePrimary.opacity(0.45))
    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
}

private func customerMemoryRow(_ memory: SalesCustomerMemory, controller: MuesliController) -> some View {
    Button {
        controller.showMeetingDocument(id: memory.latestMeetingID)
    } label: {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: "person.crop.circle.badge.clock")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 28, height: 28)
                .background(MuesliTheme.accent.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: MuesliTheme.spacing8) {
                    Text(memory.customerName)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    readinessPill("\(memory.callCount) call\(memory.callCount == 1 ? "" : "s")", good: true)
                }
                compactList("Signals", memory.knownSignals, color: MuesliTheme.accent)
                compactList("Open", memory.openActionItems, color: MuesliTheme.success)
                Text("Next: \(memory.nextBestMove)")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }
    .buttonStyle(.plain)
}

private func compactList(_ label: String, _ values: [String], color: Color) -> some View {
    Group {
        if !values.isEmpty {
            Text("\(label): \(values.prefix(2).joined(separator: "; "))")
                .font(MuesliTheme.caption())
                .foregroundStyle(color)
                .lineLimit(2)
        }
    }
}

private func smallIconButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(MuesliTheme.textSecondary)
            .frame(width: 28, height: 28)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
    }
    .buttonStyle(.plain)
}

private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private func scoreColor(_ score: Int) -> Color {
    if score >= 75 { return MuesliTheme.success }
    if score >= 55 { return MuesliTheme.accent }
    return MuesliTheme.transcribing
}

private func callActionItemRow(_ item: SalesCallActionItem, controller: MuesliController) -> some View {
    Button {
        controller.showMeetingDocument(id: item.meetingID)
    } label: {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: "checklist")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MuesliTheme.success)
                .frame(width: 24, height: 24)
                .background(MuesliTheme.success.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: MuesliTheme.spacing8) {
                    Text(item.title)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    priorityPill(item.priority)
                    if let dueHint = item.dueHint {
                        readinessPill(dueHint, good: item.priority != "high")
                    }
                }
                Text(item.evidence)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
                Text(item.meetingTitle)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }
    .buttonStyle(.plain)
}

private func callInsightRow(_ insight: SalesCallInsight, controller: MuesliController) -> some View {
    Button {
        controller.showMeetingDocument(id: insight.meetingID)
    } label: {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: iconName(forInsightKind: insight.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color(forInsightPriority: insight.priority))
                .frame(width: 24, height: 24)
                .background(color(forInsightPriority: insight.priority).opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: MuesliTheme.spacing8) {
                    Text(insight.name)
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .lineLimit(1)
                    readinessPill(insight.kind.replacingOccurrences(of: "_", with: " "), good: true)
                    priorityPill(insight.priority)
                }
                Text(insight.evidence)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
                Text(insight.guidance)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.surfacePrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }
    .buttonStyle(.plain)
}

private func priorityPill(_ priority: String) -> some View {
    let high = priority == "high"
    let low = priority == "low"
    let color = high ? MuesliTheme.transcribing : low ? MuesliTheme.textTertiary : MuesliTheme.accent
    return Text(priority)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
}

private func iconName(forInsightKind kind: String) -> String {
    switch kind {
    case "buying_signal", "close":
        return "hand.thumbsup.fill"
    case "competitor":
        return "rectangle.stack.fill"
    case "pricing":
        return "creditcard.fill"
    case "action_item":
        return "checklist"
    default:
        return "exclamationmark.bubble.fill"
    }
}

private func color(forInsightPriority priority: String) -> Color {
    switch priority {
    case "high":
        return MuesliTheme.transcribing
    case "low":
        return MuesliTheme.textTertiary
    default:
        return MuesliTheme.accent
    }
}

private func emptyLine(_ text: String) -> some View {
    Text(text)
        .font(MuesliTheme.body())
        .foregroundStyle(MuesliTheme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, MuesliTheme.spacing16)
}

private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(MuesliTheme.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
}
