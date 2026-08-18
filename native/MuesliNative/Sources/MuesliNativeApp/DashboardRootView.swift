import SwiftUI
import MuesliCore

struct DashboardRootView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var featureTourTargetFrames: [FeatureTourTarget: CGRect] = [:]

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(appState: appState, controller: controller)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } detail: {
            detailContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MuesliTheme.backgroundBase)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.left")
                }
                .keyboardShortcut(sidebarKeyboardShortcut)
                .help("Show or hide the sidebar (\(appState.config.sidebarToggleHotkey.displayLabel))")
                .accessibilityLabel("Toggle Sidebar")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(appState.config.darkMode ? .dark : .light)
        .onPreferenceChange(FeatureTourTargetPreferenceKey.self) { frames in
            guard FeatureTourFrameTracking.hasMeaningfulChange(
                from: featureTourTargetFrames,
                to: frames
            ) else { return }
            featureTourTargetFrames = frames
        }
        .overlay {
            GeometryReader { proxy in
                if let invitation = appState.pendingFeatureTourInvitation {
                    FeatureTourInvitationView(
                        tour: invitation,
                        onAccept: { controller.acceptFeatureTourInvitation() },
                        onSkip: { controller.skipFeatureTourInvitation() }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .zIndex(101)
                } else if let tour = appState.activeFeatureTour,
                   tour.steps.indices.contains(appState.featureTourStepIndex),
                   let globalTargetFrame = featureTourTargetFrames[tour.steps[appState.featureTourStepIndex].target] {
                    let globalRootFrame = proxy.frame(in: .global)
                    let targetFrame = globalTargetFrame.offsetBy(
                        dx: -globalRootFrame.minX,
                        dy: -globalRootFrame.minY
                    )
                    FeatureTourOverlay(
                        tour: tour,
                        stepIndex: appState.featureTourStepIndex,
                        spotlightRect: targetFrame,
                        containerSize: proxy.size,
                        onBack: { controller.showPreviousFeatureTourStep() },
                        onNext: { controller.showNextFeatureTourStep() },
                        onDismiss: { controller.dismissFeatureTour() }
                    )
                    .zIndex(100)
                }
            }
        }
        .alert(
            appState.contributionMilestonePrompt?.title ?? "Muesli milestone",
            isPresented: Binding(
                get: { appState.contributionMilestonePrompt != nil },
                set: { if !$0 { controller.dismissContributionMilestonePrompt() } }
            )
        ) {
            if appState.contributionMilestonePrompt?.showGitHubStar == true {
                Button("Star on GitHub") {
                    controller.openContributionMilestoneAction(.githubStar)
                }
            }
            if appState.contributionMilestonePrompt?.showBuyMeCoffee == true {
                Button("Buy Me a Coffee") {
                    controller.openContributionMilestoneAction(.buyMeCoffee)
                }
            }
            if appState.contributionMilestonePrompt?.showTweetAboutMuesli == true {
                Button("Tweet about Muesli") {
                    controller.openContributionMilestoneAction(.tweetAboutMuesli)
                }
            }
            if appState.contributionMilestonePrompt?.showPostOnLinkedIn == true {
                Button("Post about Muesli on LinkedIn") {
                    controller.openContributionMilestoneAction(.postOnLinkedIn)
                }
            }
            Button("Later", role: .cancel) {
                controller.dismissContributionMilestonePrompt()
            }
        } message: {
            Text(appState.contributionMilestonePrompt?.message ?? "")
        }
        .onAppear {
            controller.recordContributionMilestonePromptSeen()
        }
        .onChange(of: appState.contributionMilestonePrompt?.id) { _, _ in
            controller.recordContributionMilestonePromptSeen()
        }
        .sheet(
            item: Binding<DiagnosticIncident?>(
                get: { appState.pendingDiagnosticIncident },
                set: { if $0 == nil { controller.dismissDiagnosticIncidentPrompt() } }
            )
        ) { incident in
            DiagnosticIncidentReportView(
                incident: incident,
                onOpenIssue: { controller.openDiagnosticIncidentIssue(incident) },
                onDismiss: { controller.dismissDiagnosticIncidentPrompt() }
            )
        }
    }

    private var sidebarKeyboardShortcut: KeyboardShortcut {
        let configured = appState.config.sidebarToggleHotkey
        let hotkey = configured.isCombination ? configured : .sidebarToggleDefault
        let keyCode = hotkey.combinationKeyCode ?? HotkeyConfig.sidebarToggleDefault.combinationKeyCode ?? 11
        let keyLabel = HotkeyConfig.letterLabel(for: keyCode) ?? "B"
        let key = KeyEquivalent(Character(keyLabel.lowercased()))
        let flags = hotkey.resolvedCombinationModifiers ?? [.command]
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    private func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    @ViewBuilder
    private var detailContent: some View {
        if appState.isSearchActive,
           case .document(let id) = appState.meetingsNavigationState {
            MeetingDetailView(
                meeting: appState.selectedMeeting,
                controller: controller,
                appState: appState,
                onBack: {
                    appState.meetingsNavigationState = .browser
                    appState.selectedMeetingID = nil
                    appState.selectedMeetingRecord = nil
                },
                backLabel: "Back to Search"
            )
            .id(id)
        } else if appState.selectedTab == .timeline,
                  appState.meetingDetailReturnDestination == .timeline,
                  case .document(let id) = appState.meetingsNavigationState {
            MeetingDetailView(
                meeting: appState.selectedMeeting,
                controller: controller,
                appState: appState,
                onBack: { controller.showTimelineHome() },
                backLabel: "Back to Timeline"
            )
            .id(id)
        } else if appState.isSearchActive {
            SearchResultsView(appState: appState, controller: controller)
        } else {
            switch appState.selectedTab {
            case .timeline:
                TimelineView(appState: appState, controller: controller)
            case .dictations:
                DictationsView(appState: appState, controller: controller)
            case .insights:
                InsightsView(
                    initialSection: appState.insightsInitialSection,
                    loadSnapshot: { range in try await controller.insightsSnapshot(range: range) },
                    onBack: { controller.closeInsights() },
                    backLabel: appState.insightsBackLabel
                )
            case .meetings:
                MeetingsView(appState: appState, controller: controller)
            case .dictionary:
                DictionaryView(appState: appState, controller: controller)
            case .models:
                ModelsView(appState: appState, controller: controller)
            case .shortcuts:
                ShortcutsView(appState: appState, controller: controller)
            case .settings:
                SettingsView(appState: appState, controller: controller)
            case .about:
                AboutView(
                    appState: appState,
                    onOpenManualDiagnosticReport: { controller.openManualDiagnosticReport() },
                    onSetAutomaticDiagnosticIssuePrompts: { controller.setAutomaticDiagnosticIssuePrompts($0) }
                )
            }
        }
    }
}
