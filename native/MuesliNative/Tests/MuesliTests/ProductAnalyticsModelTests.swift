import Testing
@testable import MuesliNativeApp

@Suite("Product analytics catalog privacy")
struct ProductAnalyticsModelTests {
    @Test func customEndpointsCannotDiscloseEvenPublicLookingModelNames() {
        for provider in ["ollama", "lmstudio", "custom-llm", "custom_llm"] {
            #expect(AnalyticsModel.catalog(provider: provider, model: "gpt-6.1-sol").model == "custom")
        }
    }
    @Test func catalogsAreAllowedButPrivateModelNamesAreNot() {
        for option in BackendOption.catalog(appleSpeechAvailable: true).all {
            #expect(AnalyticsModel.catalog(provider: option.backend, model: option.model).model == option.model)
        }
        #expect(AnalyticsModel.catalog(provider: "openrouter", model: "private/team-model").model == "custom")
        #expect(AnalyticsModel.catalog(provider: "openai", model: "gpt-6.1-sol").model == "gpt-6.1-sol")
    }
}
