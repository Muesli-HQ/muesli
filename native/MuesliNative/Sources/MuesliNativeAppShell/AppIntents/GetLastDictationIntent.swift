import AppIntents

@available(macOS 13.0, *)
struct GetLastDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Dictation"
    static var description = IntentDescription("Returns the text of your most recent Muesli dictation.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = try MuesliShortcutsStore.open()
        guard let dictation = try store.recentDictations(limit: 1).first else {
            throw MuesliShortcutsError.noDictations
        }
        return .result(value: dictation.rawText)
    }
}
