import AppIntents
import MuesliNativeApp

@available(macOS 13.0, *)
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription("Starts hands-free Muesli dictation, same as double-tapping the dictation hotkey.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let controller = MuesliController.current else {
            throw MuesliShortcutsError.notRunning
        }
        return .result(value: controller.startDictationForShortcuts())
    }
}
