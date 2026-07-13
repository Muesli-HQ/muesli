import AppIntents
import MuesliNativeApp

@available(macOS 13.0, *)
struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Dictation"
    static var description = IntentDescription("Stops an in-progress hands-free Muesli dictation and pastes/inserts the transcript.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let controller = MuesliController.current else {
            throw MuesliShortcutsError.notRunning
        }
        return .result(value: controller.stopDictationForShortcuts())
    }
}
