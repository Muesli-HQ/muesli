import AppKit
import Contacts
import ContactsUI
import MuesliCore
import Testing
@testable import MuesliNativeApp

extension MeetingNotificationControllerTests {
    @Test @MainActor
    func completionLabelsFitSplitButton() {
        #expect(MeetingNotificationController.splitButtonLabelFits("Add Contact"))
        #expect(MeetingNotificationController.splitButtonLabelFits("Add Another"))
    }

    @Test @MainActor
    func completionLoadsExistingPeopleAndCompactsNames() async {
        let fixture = CompletionContactFixture()
        fixture.people = [fixture.person("one", "Alex"), fixture.person("two", "Sam"), fixture.person("three", "Robin")]
        let session = fixture.session()
        await session.load()
        #expect(session.participantSummary(maxWidth: 300) == "With Alex, Sam +1")
        #expect(session.participantSummary(maxWidth: 65).contains("+2"))
        #expect(session.buttonLabel == "Add Contact")
        #expect(!session.isBusy)
    }

    @Test @MainActor
    func completionPickPreservesSelectedIdentityAndRefreshesPeople() async {
        let fixture = CompletionContactFixture()
        let selected = fixture.contact("Alex", email: "alex@example.test")
        fixture.resolvedContact = fixture.contact("Alex Example", email: "other@example.test")
        let session = fixture.session()
        await session.load()
        #expect(await session.select(selected) == .added)
        #expect(fixture.attached == [MeetingParticipantDraft(participantIdentifier: "email:alex@example.test", displayName: "Alex Example", emailAddress: "other@example.test")])
        #expect(fixture.notifications == 1)
        #expect(session.participantSummary(maxWidth: 300) == "With Alex Example")
        #expect(session.buttonLabel == "Add Another")
        #expect(session.participants.first?.meetingID == 42)
        #expect(session.errorMessage == nil)
        #expect(await session.select(selected) == .duplicate)
        #expect(fixture.attached.count == 1)
        #expect(fixture.notifications == 1)
    }

    @Test @MainActor
    func completionDeduplicatesCalendarEmailAndReloadsBeforeWrite() async {
        let fixture = CompletionContactFixture()
        let session = fixture.session()
        await session.load()
        fixture.people = [fixture.person("calendar:alex", "Alex", email: " ALEX@EXAMPLE.TEST ")]
        #expect(await session.select(fixture.contact("Alex", email: "alex@example.test")) == .duplicate)
        #expect(fixture.attached.isEmpty)
        #expect(session.buttonLabel == "Add Contact")
        #expect(session.participants.count == 1)
    }

    @Test @MainActor
    func completionDeduplicatesSecondaryContactEmail() async {
        let fixture = CompletionContactFixture()
        fixture.people = [fixture.person("calendar:alex", "Alex", email: " WORK@EXAMPLE.TEST ")]
        let contact = CNMutableContact()
        contact.givenName = "Alex"
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "home@example.test" as NSString),
            CNLabeledValue(label: CNLabelWork, value: "work@example.test" as NSString),
        ]
        let session = fixture.session()
        await session.load()
        #expect(await session.select(contact) == .duplicate)
        #expect(fixture.attached.isEmpty)
        #expect(fixture.notifications == 0)
        #expect(session.participants.count == 1)
    }

    @Test @MainActor
    func completionReadFailureAndAttachFailureAllowRetry() async {
        let fixture = CompletionContactFixture()
        fixture.failLoad = true
        let session = fixture.session()
        await session.load()
        #expect(session.errorMessage == "Couldn't load contacts")
        #expect(!session.isBusy)
        #expect(await session.select(fixture.contact("Alex")) == .failed)
        #expect(fixture.attached.isEmpty)
        fixture.failLoad = false
        fixture.failAttach = true
        #expect(await session.select(fixture.contact("Alex")) == .failed)
        #expect(session.errorMessage == "Couldn't add contact")
        #expect(session.participants.isEmpty)
        #expect(session.buttonLabel == "Add Contact")
        fixture.failAttach = false
        #expect(await session.select(fixture.contact("Alex")) == .added)
        #expect(session.errorMessage == nil)
        #expect(await session.select(fixture.contact("Sam")) == .added)
        #expect(session.participants.count == 2)
    }

    @Test @MainActor
    func completionCommittedPickSurvivesRefreshFailure() async {
        let fixture = CompletionContactFixture()
        fixture.failRefresh = true
        let session = fixture.session()
        await session.load()
        #expect(await session.select(fixture.contact("Alex")) == .added)
        #expect(session.participantSummary(maxWidth: 300) == "With Alex")
        #expect(fixture.notifications == 1)
        #expect(session.errorMessage == nil)
    }

    @Test @MainActor
    func completionCloseDuringResolvePreventsPersistence() async {
        let fixture = CompletionContactFixture()
        let gate = CompletionContactGate<CNContact>()
        let session = fixture.session(resolve: { _ in await gate.wait() })
        await session.load()
        let selection = Task { await session.select(fixture.contact("Alex")) }
        await gate.waitUntilEntered()
        #expect(session.isBusy)
        #expect(await session.select(fixture.contact("Sam")) == .cancelled)
        session.invalidate()
        gate.resume(fixture.contact("Alex"))
        #expect(await selection.value == .cancelled)
        #expect(fixture.attached.isEmpty)
        #expect(fixture.notifications == 0)
    }

    @Test @MainActor
    func completionCloseDuringWriteStillBroadcastsCommittedChange() async {
        let fixture = CompletionContactFixture()
        let gate = CompletionContactGate<Void>()
        let session = fixture.session(attach: { _ in await gate.wait() })
        await session.load()
        var updates = 0
        session.onChange = { updates += 1 }
        let selection = Task { await session.select(fixture.contact("Alex")) }
        await gate.waitUntilEntered()
        session.invalidate()
        let updatesAtClose = updates
        gate.resume(())
        #expect(await selection.value == .cancelled)
        #expect(fixture.notifications == 1)
        #expect(updates == updatesAtClose)
    }

    @Test @MainActor
    func completionCardRendersSharedSplitButtonAndBodyOpensNotes() async throws {
        let fixture = CompletionContactFixture()
        fixture.people = [fixture.person("one", "Alex"), fixture.person("two", "Sam"), fixture.person("three", "Robin")]
        let session = fixture.session()
        await session.load()
        let picker = CompletionContactPickerFake()
        let controller = makeCompletionNotificationController(contactPicker: picker)
        defer { controller.close() }
        var opened = 0
        #expect(controller.show(title: "Transcription complete", subtitle: "A long meeting title that should truncate without hiding the people", completionSession: session, onStartRecording: { opened += 1 }))
        let content = try #require(controller.panel?.contentView)
        let views = completionSubviews(content)
        let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Add Contact" })
        let caret = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "▾" })
        #expect(!views.compactMap { $0 as? NSButton }.contains { $0.title == "View Notes" })
        let people = try #require(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "completionParticipants" })
        #expect(people.stringValue == "With Alex, Sam +1")
        #expect(!people.frame.intersects(button.frame))
        #expect(people.frame.width == 316)
        button.performClick(nil)
        #expect(picker.presentations == 1)
        #expect(picker.rect.width == 150)
        #expect(picker.preferredEdge == .minY)
        #expect(controller.panel?.canBecomeKey == true)
        #expect(opened == 0)
        #expect(controller.isDismissPaused)
        controller.setDismissPause(.hover, paused: true)
        picker.finish()
        #expect(controller.panel?.canBecomeKey == false)
        #expect(controller.isDismissPaused)
        controller.setDismissPause(.hover, paused: false)
        #expect(!controller.isDismissPaused)
        caret.performClick(nil)
        #expect(picker.presentations == 2)
        #expect(opened == 0)
        picker.finish()
        let card = try #require(views.first { $0.toolTip == "Open notes" })
        #expect(card.accessibilityRole() == .group)
        let accessibleChildren = try #require(card.accessibilityChildren())
        #expect(accessibleChildren.contains { ($0 as? NSView) === button })
        #expect(accessibleChildren.contains { ($0 as? NSView) === caret })
        #expect(accessibleChildren.contains { ($0 as? NSView) === people })
        #expect(card.acceptsFirstMouse(for: nil))
        #expect(card.hitTest(NSPoint(x: card.frame.minX + button.frame.midX, y: card.frame.minY + button.frame.midY)) === button)
        let openNotes = try #require(card.accessibilityCustomActions()?.first { $0.name == "Open notes" })
        let performOpenNotes = try #require(openNotes.handler)
        #expect(performOpenNotes())
        #expect(opened == 1)
        #expect(!controller.isVisible)
    }

    @Test @MainActor
    func completionFallbackStillShowsViewNotes() throws {
        let controller = makeCompletionNotificationController()
        defer { controller.close() }
        var opened = 0
        #expect(controller.show(title: "Transcription complete", subtitle: "Meeting", actionLabel: "View Notes", onStartRecording: { opened += 1 }))
        let content = try #require(controller.panel?.contentView)
        let buttons = completionSubviews(content).compactMap { $0 as? NSButton }
        #expect(!buttons.contains { $0.title == "Add Contact" })
        let button = try #require(buttons.first { $0.title == "View Notes" })
        #expect(button.isEnabled)
    }

    @Test @MainActor
    func completionReplacementIgnoresOldPickerCallbacks() async throws {
        let fixture = CompletionContactFixture()
        let session = fixture.session()
        await session.load()
        let picker = CompletionContactPickerFake()
        let controller = makeCompletionNotificationController(contactPicker: picker)
        defer { controller.close() }
        #expect(controller.show(title: "Complete", subtitle: "First", completionSession: session, onStartRecording: {}))
        let content = try #require(controller.panel?.contentView)
        let button = try #require(completionSubviews(content).compactMap { $0 as? NSButton }.first { $0.title == "Add Contact" })
        button.performClick(nil)
        let staleSelect = try #require(picker.onSelect)
        let staleClose = try #require(picker.onClose)
        #expect(controller.show(title: "Another prompt", subtitle: "Second", onStartRecording: {}))
        staleSelect(fixture.contact("Alex"))
        staleClose()
        await Task.yield()
        #expect(fixture.attached.isEmpty)
        #expect(controller.isVisible)
        #expect(!controller.isDismissPaused)
    }

    @Test @MainActor
    func contactPresenterMissingAnchorFinishesExactlyOnce() async {
        let presenter = MeetingContactPickerPresenter()
        var finishes = 0
        presenter.present(relativeTo: NSView(), rect: .zero, preferredEdge: .maxY, onSelect: { _ in Issue.record("Missing anchor selected a contact") }, onClose: { finishes += 1 })
        presenter.close()
        await Task.yield()
        #expect(finishes == 1)
    }

    @Test @MainActor
    func completionSelectionHoldsWorkPauseAfterPickerCloses() async throws {
        let fixture = CompletionContactFixture()
        let gate = CompletionContactGate<CNContact>()
        let session = fixture.session(resolve: { _ in await gate.wait() })
        await session.load()
        let picker = CompletionContactPickerFake()
        let controller = makeCompletionNotificationController(contactPicker: picker)
        defer { controller.close() }
        #expect(controller.show(title: "Complete", subtitle: "Meeting", completionSession: session, onStartRecording: {}))
        let content = try #require(controller.panel?.contentView)
        let button = try #require(completionSubviews(content).compactMap { $0 as? NSButton }.first { $0.title == "Add Contact" })
        let caret = try #require(completionSubviews(content).compactMap { $0 as? NSButton }.first { $0.title == "▾" })
        button.performClick(nil)
        picker.choose(fixture.contact("Alex"))
        // The picker can close before the selection task has started.
        #expect(controller.isDismissPaused)
        #expect(!button.isEnabled)
        #expect(!caret.isEnabled)
        #expect((button.layer?.opacity ?? 1) < 1)
        #expect((caret.layer?.opacity ?? 1) < 1)
        await gate.waitUntilEntered()
        controller.setDismissPause(.hover, paused: true)
        gate.resume(fixture.contact("Alex"))
        while session.isBusy { await Task.yield() }
        #expect(controller.isDismissPaused)
        #expect(button.title == "Add Another")
        #expect(button.isEnabled)
        #expect(caret.isEnabled)
        #expect(button.layer?.opacity == 1)
        #expect(caret.layer?.opacity == 1)
        controller.setDismissPause(.hover, paused: false)
        #expect(!controller.isDismissPaused)
    }

    @Test @MainActor
    func completionErrorsHaveRoomBesideButtonAndRemainVisible() async throws {
        let fixture = CompletionContactFixture()
        let session = fixture.session()
        await session.load()
        let controller = makeCompletionNotificationController(contactPicker: CompletionContactPickerFake())
        defer { controller.close() }
        #expect(controller.show(title: "Complete", subtitle: "Meeting", completionSession: session, onStartRecording: {}))
        let content = try #require(controller.panel?.contentView)
        let views = completionSubviews(content)
        let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Add Contact" })
        let error = try #require(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "completionError" })
        let card = try #require(views.first { $0.toolTip == "Open notes" })
        #expect(card.accessibilityChildren()?.contains { ($0 as? NSView) === error } == true)
        fixture.failAttach = true
        #expect(await session.select(fixture.contact("Alex")) == .failed)
        #expect(error.stringValue == "Couldn't add contact")
        #expect(controller.isVisible)
        #expect(!error.frame.intersects(button.frame))
        #expect((error.stringValue as NSString).size(withAttributes: [.font: try #require(error.font)]).width <= error.frame.width)
        fixture.failLoad = true
        #expect(await session.select(fixture.contact("Alex")) == .failed)
        #expect(error.stringValue == "Couldn't load contacts")
        #expect((error.stringValue as NSString).size(withAttributes: [.font: try #require(error.font)]).width <= error.frame.width)
        #expect(controller.isVisible)
    }

    @Test @MainActor
    func completionInvalidatedInitialReadNeverUpdatesCard() async {
        let fixture = CompletionContactFixture()
        let gate = CompletionContactGate<[MeetingParticipant]>()
        let session = MeetingCompletionContactSession(meetingID: 42, loadParticipants: { await gate.wait() }, resolveContact: { $0 }, attachParticipant: { _ in Issue.record("Unexpected write") }, participantsDidChange: {})
        var changes = 0
        session.onChange = { changes += 1 }
        let loading = Task { await session.load() }
        await gate.waitUntilEntered()
        session.invalidate()
        let changesAtClose = changes
        gate.resume([fixture.person("one", "Alex")])
        await loading.value
        #expect(session.participants.isEmpty)
        #expect(changes == changesAtClose)
    }

    @Test @MainActor
    func contactPresenterCloseBeforeDeferredShowIgnoresStaleDelegate() async {
        let presenter = MeetingContactPickerPresenter()
        _ = NSApplication.shared
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = anchor
        defer { window.close() }
        var closes = 0
        var selections = 0
        presenter.present(relativeTo: anchor, rect: anchor.bounds, preferredEdge: .maxY, onSelect: { _ in selections += 1 }, onClose: { closes += 1 })
        presenter.close()
        let obsolete = CNContactPicker()
        presenter.contactPicker(obsolete, didSelect: CNMutableContact())
        presenter.contactPickerDidClose(obsolete)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(closes == 1)
        #expect(selections == 0)
    }

    @Test @MainActor
    func acceptedStopClickStillRunsWhenPromptClosesDuringFade() async throws {
        let controller = makeCompletionNotificationController()
        defer { controller.close() }
        var stopActions = 0

        #expect(controller.show(
            title: "Meeting ended",
            subtitle: "Still transcribing.",
            actionLabel: "Stop Transcribing",
            dismissAfter: 60,
            onStartRecording: { stopActions += 1 }
        ))
        let stopButton = try #require(
            controller.panel?.contentView?.subviews
                .flatMap { $0.subviews }
                .compactMap { $0 as? NSButton }
                .first { $0.title == "Stop Transcribing" }
        )

        stopButton.performClick(nil)
        controller.close()
        try await Task.sleep(for: .milliseconds(300))

        #expect(stopActions == 1)
    }

    @Test @MainActor
    func completionCloseCallbackCanShowSuccessorWithoutLosingItsCleanup() {
        let controller = makeCompletionNotificationController()
        defer { controller.close() }
        var successorCloses = 0
        var successorWasShown = false
        let firstWasShown = controller.show(title: "First", subtitle: "Meeting", onStartRecording: {}, onClose: {
            successorWasShown = controller.show(title: "Second", subtitle: "Meeting", onStartRecording: {}, onClose: { successorCloses += 1 })
        })
        #expect(firstWasShown)
        controller.close()
        #expect(successorWasShown)
        #expect(controller.isVisible)
        controller.close()
        #expect(successorCloses == 1)
    }
}

@MainActor private final class CompletionContactFixture {
    var people: [MeetingParticipant] = []
    var attached: [MeetingParticipantDraft] = []
    var notifications = 0
    var failLoad = false
    var failAttach = false
    var failRefresh = false
    var resolvedContact: CNContact?
    enum Failure: Error { case expected }

    func person(_ id: String, _ name: String, email: String? = nil) -> MeetingParticipant {
        MeetingParticipant(meetingID: 42, participantIdentifier: id, displayName: name, emailAddress: email, insertionOrder: 0)
    }

    func contact(_ name: String, email: String? = nil) -> CNContact {
        let contact = CNMutableContact()
        contact.givenName = name
        if let email { contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)] }
        return contact.copy() as! CNContact
    }

    func session(resolve: ((CNContact) async -> CNContact)? = nil, attach: ((MeetingParticipantDraft) async throws -> Void)? = nil) -> MeetingCompletionContactSession {
        MeetingCompletionContactSession(
            meetingID: 42,
            loadParticipants: {
                if self.failLoad || (self.failRefresh && !self.attached.isEmpty) { throw Failure.expected }
                return self.people
            },
            resolveContact: resolve ?? { self.resolvedContact ?? $0 },
            attachParticipant: attach ?? { draft in
                if self.failAttach { throw Failure.expected }
                self.attached.append(draft)
                self.people.append(self.person(draft.participantIdentifier, draft.displayName, email: draft.emailAddress))
            },
            participantsDidChange: { self.notifications += 1 }
        )
    }
}

@MainActor private final class CompletionContactGate<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered?.resume()
            entered = nil
        }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor private final class CompletionContactPickerFake: MeetingContactPresenting {
    var presentations = 0
    var rect = NSRect.zero
    var preferredEdge = NSRectEdge.maxY
    var onSelect: ((CNContact) -> Void)?
    var onClose: (() -> Void)?
    func present(relativeTo view: NSView, rect: NSRect, preferredEdge: NSRectEdge, onSelect: @escaping (CNContact) -> Void, onClose: @escaping () -> Void) {
        presentations += 1
        self.rect = rect
        self.preferredEdge = preferredEdge
        self.onSelect = onSelect
        self.onClose = onClose
    }
    func finish() {
        let callback = onClose
        onClose = nil
        onSelect = nil
        callback?()
    }
    func choose(_ contact: CNContact) {
        onSelect?(contact)
        finish()
    }
    func close() { finish() }
}

@MainActor private func completionSubviews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(completionSubviews)
}

@MainActor private func makeCompletionNotificationController(contactPicker: (any MeetingContactPresenting)? = nil) -> MeetingNotificationController {
    _ = NSApplication.shared
    if let contactPicker { return MeetingNotificationController(contactPicker: contactPicker) }
    return MeetingNotificationController()
}
