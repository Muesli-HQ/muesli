import AppIntents
import MuesliNativeApp

@available(macOS 13.0, *)
struct StopMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Meeting Recording"
    static var description = IntentDescription("Stops the in-progress Muesli meeting recording.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await MuesliShortcutsRuntime.waitForController()
        return .result(value: controller.stopMeetingRecordingForShortcuts())
    }
}
