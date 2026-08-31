import SwiftUI
import MuesliCore

enum DashboardWindowLayout {
    /// Narrow enough to sit beside a call window while preserving a useful
    /// notes editor when the sidebar is collapsed or hidden.
    static let minimumContentWidth: CGFloat = 520
    static let minimumContentHeight: CGFloat = 600
    static let compactQuickNotesThreshold: CGFloat = 600

    static func usesCompactQuickNotes(width: CGFloat, hasOpenMeeting: Bool) -> Bool {
        hasOpenMeeting && width < compactQuickNotesThreshold
    }
}

private struct CompactQuickNotesEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesCompactQuickNotes: Bool {
        get { self[CompactQuickNotesEnvironmentKey.self] }
        set { self[CompactQuickNotesEnvironmentKey.self] = newValue }
    }
}

struct DashboardContentLayout<SidebarContent: View, DetailContent: View>: View {
    let usesCompactQuickNotes: Bool
    @ViewBuilder let sidebar: () -> SidebarContent
    @ViewBuilder let detail: () -> DetailContent

    var body: some View {
        HSplitView {
            if !usesCompactQuickNotes {
                sidebar()
            }

            detail()
                .environment(\.usesCompactQuickNotes, usesCompactQuickNotes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MuesliTheme.backgroundBase)
        }
    }
}

struct DashboardRootView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var featureTourTargetFrames: [FeatureTourTarget: CGRect] = [:]
    @State private var isSidebarCollapsed = false

    var body: some View {
        GeometryReader { proxy in
            let usesCompactQuickNotes = DashboardWindowLayout.usesCompactQuickNotes(
                width: proxy.size.width,
                hasOpenMeeting: hasOpenMeeting
            )

            DashboardContentLayout(usesCompactQuickNotes: usesCompactQuickNotes) {
                SidebarView(
                    appState: appState,
                    controller: controller,
                    isCollapsed: isSidebarCollapsed,
                    onToggleCollapsed: {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isSidebarCollapsed.toggle()
                        }
                    }
                )
                .frame(
                    minWidth: isSidebarCollapsed ? 68 : 240,
                    idealWidth: isSidebarCollapsed ? 68 : 260,
                    maxWidth: isSidebarCollapsed ? 68 : 300
                )
            } detail: {
                detailContent
            }
        }
        .frame(
            minWidth: DashboardWindowLayout.minimumContentWidth,
            minHeight: DashboardWindowLayout.minimumContentHeight
        )
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

    private var hasOpenMeeting: Bool {
        if case .document = appState.meetingsNavigationState {
            return true
        }
        return false
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
