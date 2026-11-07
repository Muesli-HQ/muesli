import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Global search presentation")
struct GlobalSearchPresentationTests {
    @Test("People results support keyboard selection and reject stale searches")
    @MainActor func peopleSearch() async {
        let model = GlobalSearchPresentation()
        let alice = MeetingParticipantDraft(participantIdentifier: "contact:alice", displayName: "Alice")
        let bob = MeetingParticipantDraft(participantIdentifier: "contact:bob", displayName: "Bob")
        await model.refreshPeople(debounce: false) { [alice, bob] }
        #expect(model.people == [alice, bob])
        #expect(model.selection == alice.participantIdentifier)
        model.move(1)
        #expect(model.selection == bob.participantIdentifier)
        let started = AsyncStream<Void>.makeStream()
        let old = Task { @MainActor in
            await model.refreshPeople(debounce: false) {
                started.continuation.yield(())
                try await Task.sleep(for: .milliseconds(80))
                return [alice]
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        await model.refreshPeople(debounce: false) { [bob] }
        await old.value
        #expect(model.people == [bob])
    }
    @Test("Preview distinguishes temporary failures from deletion and recovers without losing selection")
    @MainActor func previewRecovery() async {
        let preview = GlobalSearchPreview()
        let source = GlobalSearchResult(kind: .dictation, sourceID: "1", date: Date(), title: "Title", excerpt: "Text", appName: "", bundleID: "", mediaAvailable: false)
        preview.show("Original", source: source)
        #expect(await preview.refresh { _ in throw CocoaError(.fileReadUnknown) } == false)
        #expect(preview.text == "Original")
        #expect(preview.source == source)
        #expect(preview.error == "Preview couldn’t refresh. Retrying…")
        #expect(await preview.refresh { _ in .text("Updated") })
        #expect(preview.text == "Updated")
        #expect(preview.error == nil)
        #expect(await preview.refresh { _ in nil })
        #expect(preview.text == nil)
        #expect(preview.source == nil)
        #expect(preview.error == "This item is no longer available.")
        preview.show("Reopened", source: source)
        _ = await preview.refresh { _ in
            preview.clear() // User navigated away before the async read completed.
            return .text("Late")
        }
        #expect(preview.text == nil)
        #expect(preview.error == nil)
    }

    @Test("Partial results remain selectable and recovery clears the availability notice")
    @MainActor func partialSearchPresentation() async {
        let model = GlobalSearchPresentation()
        let hit = GlobalSearchResult(kind: .meeting, sourceID: "1", date: Date(), title: "Meeting", excerpt: "Text", appName: "", bundleID: "", mediaAvailable: false)
        let request = GlobalSearchRequest(text: "text")
        await model.refreshResponse(request, debounce: false) { _ in
            .init(results: [hit], unavailableKinds: [.recap, .screenHistory])
        }
        #expect(model.results == [hit] && model.selection == hit.id)
        #expect(model.error == nil && model.availabilityMessage != nil)
        await model.refreshResponse(request, debounce: false) { _ in .init(results: [hit]) }
        #expect(model.selection == hit.id && model.availabilityMessage == nil)
        await model.refreshResponse(request, debounce: false) { _ in .init(unavailableKinds: [.meeting]) }
        #expect(model.results.isEmpty && model.error == nil)
        #expect(model.unavailableKinds == [.meeting])
        await model.refreshResponse(.init(), debounce: false) { _ in .init() }
        #expect(model.unavailableKinds.isEmpty)
    }

    @Test("Opening a capture replaces retained navigation, including repeated and same-day results")
    @MainActor func captureNavigation() {
        let state = AppState()
        let first = VisualMemoryItem(id: "first", kind: .moment, source: "Editor", text: "One", path: "one.png")
        var second = first
        second.id = "second"
        second.capturedAt = first.capturedAt.addingTimeInterval(60)
        state.timeTurnerShowsRecap = true
        state.openTimeTurnerCapture(first)
        let firstNavigation = state.timeTurnerNavigationID
        state.openTimeTurnerCapture(second)
        #expect(state.timeTurnerDay == second.capturedAt)
        #expect(state.timeTurnerSelectedCapture?.id == second.id)
        #expect(!state.timeTurnerShowsRecap)
        #expect(state.selectedTab == .timeTurner)
        #expect(state.timeTurnerNavigationID != firstNavigation)
        let secondNavigation = state.timeTurnerNavigationID
        // Scrubbing writes selection without resetting the viewer. Reopening the
        // same result must nevertheless create a fresh navigation request.
        state.timeTurnerSelectedCapture = first
        #expect(state.timeTurnerNavigationID == secondNavigation)
        state.openTimeTurnerCapture(second)
        #expect(state.timeTurnerSelectedCapture?.id == second.id)
        #expect(state.timeTurnerNavigationID != secondNavigation)
        second.capturedAt = first.capturedAt.addingTimeInterval(-86400)
        state.openTimeTurnerCapture(second)
        #expect(state.timeTurnerDay == second.capturedAt)
        #expect(state.timeTurnerSelectedCapture?.capturedAt == second.capturedAt)
    }

    @Test("Filters preserve typed text and apply calendar-day and source scope")
    func filters() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 19800)!
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let request = GlobalSearchRequest(text: "two words ", kind: .command, app: " Editor ", period: .today)
        let query = request.query(now: now, calendar: calendar)
        #expect(query.text == "two words ")
        #expect(query.kinds == [.command])
        #expect(query.app == "Editor")
        #expect(query.from == calendar.startOfDay(for: now))
        #expect(query.until == now)
        #expect(query.limit == 100)
        #expect(GlobalSearchRequest().query().kinds == Set(GlobalSearchKind.allCases))
    }

    @Test("A superseded query cannot publish an error over the current results")
    @MainActor func supersededQuery() async {
        let model = GlobalSearchPresentation()
        let started = AsyncStream<Void>.makeStream()
        let slow = Task { @MainActor in
            await model.refresh(.init(text: "old"), debounce: false) { _ in
                started.continuation.yield(())
                try await Task.sleep(for: .milliseconds(80))
                throw CocoaError(.fileReadUnknown)
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        await iterator.next()
        await model.refresh(.init(text: "new"), debounce: false) { _ in [] }
        await slow.value
        #expect(model.error == nil)
        #expect(!model.isLoading)
    }

    @Test("Live refresh keeps keyboard selection and clamps navigation at either end")
    @MainActor func stableSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-selection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        for title in ["Orchid one", "Orchid two"] {
            _ = try store.insertMeeting(title: title, calendarEventID: nil,
                startTime: Date().addingTimeInterval(-60), endTime: Date(),
                rawTranscript: "Notes", formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil)
        }
        let worker = GlobalSearchWorker(databaseURL: url, screenRoot: nil)
        let model = GlobalSearchPresentation()
        let request = GlobalSearchRequest(text: "orchid")
        await model.refresh(request, using: worker, debounce: false)
        #expect(model.results.count == 2)
        model.move(100)
        let selected = try #require(model.selection)
        #expect(selected == model.results.last?.id)
        _ = try store.insertMeeting(title: "Orchid new", calendarEventID: nil,
            startTime: Date().addingTimeInterval(-10), endTime: Date(),
            rawTranscript: "Notes", formattedNotes: "Notes", micAudioPath: nil, systemAudioPath: nil)
        await model.refresh(request, using: worker, debounce: false)
        #expect(model.results.count == 3)
        #expect(model.selection == selected)
        model.move(-100)
        #expect(model.selection == model.results.first?.id)
    }

    @Test("Blank search clears selection and does not query a store")
    @MainActor func emptyQuery() async {
        let model = GlobalSearchPresentation()
        model.selection = "old"
        await model.refresh(.init(text: "  \n"), debounce: false) { _ in
            Issue.record("Blank queries must not reach the store")
            return []
        }
        #expect(model.results.isEmpty)
        #expect(model.selection == nil)
        #expect(!model.isLoading)
        model.move(1)
        #expect(model.selection == nil)
    }
}
