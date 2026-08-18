import AppIntents
import MuesliNativeApp

@available(macOS 13.0, *)
struct StartMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Meeting Recording"
    static var description = IntentDescription("Starts a Muesli meeting recording, capturing mic and system audio.")
    // Ask the system to launch Muesli before performing so the in-process
    // controller exists; without this a closed app makes the wait time out.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Title", default: "Meeting")
    var meetingTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await MuesliShortcutsRuntime.waitForController()
        let started = controller.startMeetingRecordingForShortcuts(title: meetingTitle)
        return .result(value: started)
    }
}
