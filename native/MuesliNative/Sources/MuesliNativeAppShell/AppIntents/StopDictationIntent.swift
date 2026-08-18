import AppIntents
import MuesliNativeApp

@available(macOS 13.0, *)
struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Dictation"
    static var description = IntentDescription("Stops an in-progress hands-free Muesli dictation and pastes/inserts the transcript.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await MuesliShortcutsRuntime.waitForController()
        return .result(value: controller.stopDictationForShortcuts())
    }
}
