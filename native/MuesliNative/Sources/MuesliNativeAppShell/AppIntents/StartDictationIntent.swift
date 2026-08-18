import AppIntents
import MuesliNativeApp

@available(macOS 13.0, *)
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription("Starts hands-free Muesli dictation, same as double-tapping the dictation hotkey.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await MuesliShortcutsRuntime.waitForController()
        return .result(value: controller.startDictationForShortcuts())
    }
}
