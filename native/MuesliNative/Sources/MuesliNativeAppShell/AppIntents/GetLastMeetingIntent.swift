import AppIntents
import Foundation

@available(macOS 13.0, *)
struct GetLastMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Meeting Notes"
    static var description = IntentDescription("Returns the formatted notes from your most recent Muesli meeting.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = try MuesliShortcutsStore.open()
        guard let meeting = try store.recentMeetings(limit: 1).first else {
            throw MuesliShortcutsError.noMeetings
        }
        let notes = meeting.formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return .result(value: notes.isEmpty ? meeting.rawTranscript : notes)
    }
}
