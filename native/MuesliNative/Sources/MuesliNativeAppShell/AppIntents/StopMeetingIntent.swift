import AppIntents
import MuesliNativeApp

@available(macOS 13.0, *)
struct StopMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Meeting Recording"
    static var description = IntentDescription("Stops the in-progress Muesli meeting recording.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let controller = MuesliController.current else {
            throw MuesliShortcutsError.notRunning
        }
        controller.stopMeetingRecordingForShortcuts()
        return .result()
    }
}
