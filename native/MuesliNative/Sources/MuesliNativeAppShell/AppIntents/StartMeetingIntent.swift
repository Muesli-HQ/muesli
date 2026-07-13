import AppIntents
import MuesliNativeApp

@available(macOS 13.0, *)
struct StartMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Meeting Recording"
    static var description = IntentDescription("Starts a Muesli meeting recording, capturing mic and system audio.")

    @Parameter(title: "Title", default: "Meeting")
    var meetingTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        guard let controller = MuesliController.current else {
            throw MuesliShortcutsError.notRunning
        }
        let started = controller.startMeetingRecordingForShortcuts(title: meetingTitle)
        return .result(value: started)
    }
}
