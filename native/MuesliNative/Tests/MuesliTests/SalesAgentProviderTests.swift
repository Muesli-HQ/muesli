import Testing
@testable import MuesliNativeApp

@Suite("Sales agent provider")
struct SalesAgentProviderTests {
    @Test("Jessica defaults to hosted Railway provider")
    func defaultsToHostedJessica() {
        let config = AppConfig()

        #expect(config.salesAgentBackend == SalesAgentBackendOption.hostedJessica.backend)
        #expect(SalesAgentBackendOption.resolved(nil).backend == SalesAgentBackendOption.hostedJessica.backend)
        #expect(SalesAgentBackendOption.resolved(SalesAgentBackendOption.localPlanner.backend).backend == SalesAgentBackendOption.hostedJessica.backend)
        #expect(!SalesAgentBackendOption.all.contains { $0.backend == SalesAgentBackendOption.localPlanner.backend })
    }

    @Test("Jessica command requests cannot request desktop control")
    func commandRequestsCannotRequestDesktopControl() {
        var config = AppConfig()
        config.salesAgentAllowComputerActions = true
        config.salesAgentSendScreenContext = true
        config.salesAgentUserID = "kaden"
        config.salesAgentUserName = "Kaden"
        config.salesAgentUserRole = "rep"
        config.salesAgentRepKey = "kaden"

        let request = SalesAgentProvider.commandRequest(
            transcript: "How many dials did each rep make today?",
            config: config
        )

        #expect(request.allowComputerActions == false)
        #expect(request.sendScreenContext == false)
        #expect(request.speaker?.userID == "kaden")
        #expect(request.speaker?.name == "Kaden")
        #expect(request.speaker?.role == "rep")
        #expect(request.speaker?.repKey == "kaden")
    }

    @Test("Jessica command requests include recent conversation history")
    func commandRequestsIncludeRecentConversationHistory() {
        var config = AppConfig()
        config.salesAgentHistory = [
            SalesAgentHistoryItem(
                transcript: "Move my appointment",
                response: "I found two appointments. Which one should I move?"
            ),
            SalesAgentHistoryItem(
                transcript: "How many dials did I make today?",
                response: "You made 42 dials today."
            ),
        ]

        let request = SalesAgentProvider.commandRequest(
            transcript: "The second one",
            config: config
        )

        #expect(request.conversationHistory.map(\.role) == ["user", "assistant", "user", "assistant"])
        #expect(request.conversationHistory[2].content == "Move my appointment")
        #expect(request.conversationHistory[3].content == "I found two appointments. Which one should I move?")
    }
}
