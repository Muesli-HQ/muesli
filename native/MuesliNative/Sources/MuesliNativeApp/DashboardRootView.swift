import SwiftUI
import MuesliCore

struct DashboardRootView: View {
    let appState: AppState
    let controller: MuesliController

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
                AboutView(appState: appState)
            }
        }
    }
}
