import SwiftUI
import MuesliCore

struct DashboardRootView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var featureTourTargetFrames: [FeatureTourTarget: CGRect] = [:]

    var body: some View {
        NavigationSplitView {
            SidebarView(appState: appState, controller: controller)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } detail: {
            detailContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MuesliTheme.backgroundBase)
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
        } else if appState.isSearchActive {
            SearchResultsView(appState: appState, controller: controller)
        } else {
            switch appState.selectedTab {
            case .dictations:
                DictationsView(appState: appState, controller: controller)
            case .insights:
                InsightsView(
                    initialSection: appState.insightsInitialSection,
                    loadSnapshot: { range in try await controller.insightsSnapshot(range: range) },
                    onBack: { controller.closeInsights() }
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
