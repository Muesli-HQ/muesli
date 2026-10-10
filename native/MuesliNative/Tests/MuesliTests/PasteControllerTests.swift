import Testing
import AppKit
@testable import MuesliNativeApp

// .serialized: some tests still post keyboard events into the active session.
@Suite("PasteController — clipboard-preserving paste and keystroke simulation", .serialized)
@MainActor
struct PasteControllerTests {

    private let clipboardPollInterval: TimeInterval = 0.05
    private let clipboardRestoreTimeout: TimeInterval = 2.0

    // MARK: - typeText tests

    @Test("typeText with empty string does not crash")
    func typeTextEmpty() {
        // Early-return guard: no CGEvents posted, no clipboard access
        PasteController.typeText("")
    }

    @Test("typeText does not modify the system clipboard")
    func typeTextPreservesClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("clipboard-sentinel", forType: .string)

        // Post a single space via CGEvent (minimal side-effect in test runner)
        PasteController.typeText(" ")

        // Clipboard must be unchanged — this is the whole point of typeText
        #expect(pasteboard.string(forType: .string) == "clipboard-sentinel")
    }

    @Test("common ASCII text uses physical keyboard path")
    func commonASCIIUsesPhysicalKeyboardPath() {
        #expect(PasteController.canTypeUsingPhysicalKeys("Hello, world! 123"))
        #expect(PasteController.canTypeUsingPhysicalKeys("this has been created using computer use"))
        #expect(!PasteController.canTypeUsingPhysicalKeys("नमस्ते"))
    }

    @Test("browser selection copy returns exact text and restores every clipboard item")
    func browserSelectionCopyRestoresClipboard() {
        let pasteboard = makePasteboard()
        let item1 = NSPasteboardItem()
        item1.setString("item-one", forType: .string)
        let item2 = NSPasteboardItem()
        item2.setString("item-two", forType: .string)
        pasteboard.writeObjects([item1, item2])

        let selected = PasteController.copySelectedText(
            pasteboard: pasteboard,
            timeout: 0,
            simulateCopyAction: {
                pasteboard.clearContents()
                pasteboard.setString("  selected Google Docs text\n", forType: .string)
                return true
            }
        )

        #expect(selected == "  selected Google Docs text\n")
        let restored = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }
        #expect(restored == ["item-one", "item-two"])
    }

    @Test("browser selection copy leaves clipboard unchanged when copy produces nothing")
    func browserSelectionCopyWithoutSelectionPreservesClipboard() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let selected = PasteController.copySelectedText(
            pasteboard: pasteboard,
            timeout: 0,
            simulateCopyAction: { true }
        )

        #expect(selected == nil)
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("UTF-16 encoding of SentencePiece leading-space deltas is correct")
    func sentencePieceLeadingSpaceUTF16() {
        // Nemotron streaming produces " word" (SentencePiece ▁ → " ").
        // typeText iterates Character.utf16, so verify round-trip is exact.
        let delta = " hello"
        let utf16 = Array(delta.utf16)
        // First code unit must be a space
        #expect(utf16.first == UInt16((" " as Unicode.Scalar).value))
        // All BMP characters: count == Swift character count
        #expect(utf16.count == delta.count)
        // Full round-trip
        let roundTripped = utf16.map { Character(Unicode.Scalar($0)!) }
        #expect(String(roundTripped) == delta)
    }

    @Test("UTF-16 round-trip for multi-word streaming deltas")
    func multiWordDeltaEncoding() {
        let deltas = [" world", " how are you", " testing one two"]
        for delta in deltas {
            let utf16 = Array(delta.utf16)
            let decoded = String(utf16.map { Character(Unicode.Scalar($0)!) })
            #expect(decoded == delta, "Round-trip failed for: \(delta)")
        }
    }

    // MARK: - paste() clipboard restoration

    @Test("custom shortcut reaches keyboard dispatch without changing clipboard safety")
    func customPasteShortcut() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        let chord = try #require(PasteKeyChord(keyCode: 47, modifiers: .maskControl))
        var dispatched: PasteShortcut?
        PasteController.paste(text: "dictated", pasteboard: pasteboard, shortcut: .custom(chord), snapshotWorker: makeTestClipboardSnapshotWorker(),
            requireStagedClipboardOwnership: true, simulatePasteAction: { shortcut in
                dispatched = shortcut
                return true
            })
        #expect(await waitForClipboardString(in: pasteboard, expected: "dictated") == "dictated")
        let restored = await waitForClipboardString(in: pasteboard, expected: "original")
        #expect(restored == "original")
        #expect(dispatched == .custom(chord))
    }

    @Test("paste with empty string is a no-op")
    func pasteEmptyIsNoOp() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "", pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(), simulatePasteAction: { _ in true })

        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("paste temporarily writes text to clipboard for Cmd+V")
    func pasteWritesTextToClipboard() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(), simulatePasteAction: { _ in true })

        // Snapshotting is asynchronous; staging still precedes the Paste command.
        #expect(await waitForClipboardString(in: pasteboard, expected: "dictated text") == "dictated text")

        _ = await waitForClipboardString(in: pasteboard, expected: "original")
    }

    @Test("paste cancellation rechecks target and restores clipboard without Cmd+V")
    func pasteCancellationRestoresClipboard() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        var didSimulatePaste = false
        let result = await withCheckedContinuation { continuation in
            PasteController.paste(
                text: "replacement",
                pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                requireStagedClipboardOwnership: true,
                shouldDispatchPaste: { false },
                simulatePasteAction: { _ in
                    didSimulatePaste = true
                    return true
                },
                onPasteFinished: { application in
                    continuation.resume(returning: application)
                }
            )
        }
        #expect(result == nil)
        #expect(!didSimulatePaste)
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("Quill cancellation retains generated text for manual paste")
    func pasteCancellationRetainsClipboardFallback() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        var shouldDispatch = true
        var lifecycleEvents: [PasteController.LifecycleEvent] = []

        let result = await withCheckedContinuation { continuation in
            PasteController.paste(
                text: "Quill output",
                pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                requireStagedClipboardOwnership: true,
                shouldDispatchPaste: { shouldDispatch },
                retainStagedTextOnFailure: true,
                onPasteFinished: { application in
                    continuation.resume(returning: application)
                },
                onLifecycleEvent: {
                    lifecycleEvents.append($0)
                    if $0 == .clipboardStaged { shouldDispatch = false }
                }
            )
        }

        #expect(result == nil)
        #expect(lifecycleEvents.contains(.pasteDispatchCancelled))
        #expect(lifecycleEvents.contains(.clipboardRetainedForManualPaste))
        #expect(pasteboard.string(forType: .string) == "Quill output")
    }

    @Test("paste reports the application snapshotted at Cmd+V dispatch")
    func pasteReportsApplicationAtCommandDispatch() async {
        let pasteboard = makePasteboard()
        let expectedApplication = NSRunningApplication.current

        let result = await withCheckedContinuation { continuation in
            var events: [String] = []
            PasteController.paste(
                text: "dictated text",
                pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                targetApplicationProvider: {
                    events.append("snapshot")
                    return expectedApplication
                },
                simulatePasteAction: { _ in
                    events.append("command")
                    return true
                },
                onPasteFinished: { application in
                    events.append("callback")
                    continuation.resume(returning: (events, application?.processIdentifier))
                }
            )
        }

        #expect(result.0 == ["snapshot", "command", "callback"])
        #expect(result.1 == expectedApplication.processIdentifier)
        _ = await waitForClipboardString(in: pasteboard, expected: nil)
    }

    @Test("paste dispatch callback runs only after a successful command")
    func pasteDispatchCallbackRequiresSuccessfulCommand() async {
        let successfulPasteboard = makePasteboard()
        let successfulEvents = await withCheckedContinuation { continuation in
            var events: [String] = []
            PasteController.paste(
                text: "Quill replacement",
                pasteboard: successfulPasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                simulatePasteAction: { _ in
                    events.append("command")
                    return true
                },
                onPasteDispatched: {
                    events.append("dispatched")
                },
                onPasteFinished: { _ in
                    events.append("finished")
                    continuation.resume(returning: events)
                }
            )
        }
        #expect(successfulEvents == ["command", "dispatched", "finished"])

        let failedPasteboard = makePasteboard()
        let failedEvents = await withCheckedContinuation { continuation in
            var events: [String] = []
            PasteController.paste(
                text: "Quill replacement",
                pasteboard: failedPasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                simulatePasteAction: { _ in
                    events.append("command")
                    return false
                },
                onPasteDispatched: {
                    events.append("dispatched")
                },
                onPasteFinished: { _ in
                    events.append("finished")
                    continuation.resume(returning: events)
                }
            )
        }
        #expect(failedEvents == ["command", "finished"])

        _ = await waitForClipboardString(in: successfulPasteboard, expected: nil)
        _ = await waitForClipboardString(in: failedPasteboard, expected: nil)
    }

    @Test("target application Paste command bypasses the global keyboard shortcut")
    func targetApplicationPasteCommandDispatchesDirectly() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let expectedApplication = NSRunningApplication.current
        var didPostKeyboardShortcut = false

        let result = await withCheckedContinuation { continuation in
            var lifecycleEvents: [PasteController.LifecycleEvent] = []
            PasteController.paste(
                text: "Quill output",
                pasteboard: pasteboard,
                shortcut: .custom(PasteKeyChord(keyCode: 47, modifiers: .maskControl)!),
                snapshotWorker: makeTestClipboardSnapshotWorker(),
                targetApplicationProvider: { expectedApplication },
                dispatchStrategy: .targetApplicationPasteCommand,
                targetPasteAction: { application in
                    #expect(application.processIdentifier == expectedApplication.processIdentifier)
                    return true
                },
                simulatePasteAction: { _ in
                    didPostKeyboardShortcut = true
                    return true
                },
                onPasteFinished: { application in
                    continuation.resume(returning: (
                        application?.processIdentifier,
                        lifecycleEvents
                    ))
                },
                onLifecycleEvent: { lifecycleEvents.append($0) }
            )
        }

        #expect(result.0 == expectedApplication.processIdentifier)
        #expect(!didPostKeyboardShortcut)
        #expect(result.1.contains(.targetPasteCommandDispatched))
        #expect(result.1.contains(.pasteDispatched))
        _ = await waitForClipboardString(in: pasteboard, expected: "original")
    }

    @Test("target Paste Accessibility requests use only the remaining traversal budget")
    func targetPasteAXTimeoutUsesRemainingBudget() {
        let now = Date(timeIntervalSince1970: 1_777_000_000)

        #expect(PasteController.targetPasteAXTimeout(
            until: now.addingTimeInterval(1),
            now: now
        ) == 0.1)
        let nearlyExpired = PasteController.targetPasteAXTimeout(
            until: now.addingTimeInterval(0.025),
            now: now
        )
        #expect(nearlyExpired != nil)
        #expect(abs((nearlyExpired ?? 0) - 0.025) < 0.000_001)
        #expect(PasteController.targetPasteAXTimeout(until: now, now: now) == nil)
        #expect(PasteController.targetPasteAXTimeout(
            until: now.addingTimeInterval(-1),
            now: now
        ) == nil)
    }

    @Test("rejected target Paste command retains Quill output for manual paste")
    func rejectedTargetPasteCommandRetainsClipboardFallback() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        var didPostKeyboardShortcut = false

        let result = await withCheckedContinuation { continuation in
            var lifecycleEvents: [PasteController.LifecycleEvent] = []
            PasteController.paste(
                text: "Quill output",
                pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                targetApplicationProvider: { NSRunningApplication.current },
                dispatchStrategy: .targetApplicationPasteCommand,
                retainStagedTextOnFailure: true,
                targetPasteAction: { _ in false },
                simulatePasteAction: { _ in
                    didPostKeyboardShortcut = true
                    return true
                },
                onPasteFinished: { application in
                    continuation.resume(returning: (application, lifecycleEvents))
                },
                onLifecycleEvent: { lifecycleEvents.append($0) }
            )
        }

        #expect(result.0 == nil)
        #expect(!didPostKeyboardShortcut)
        #expect(result.1 == [
            .clipboardSnapshotBegun,
            .clipboardSnapshotCompleted,
            .clipboardStaged,
            .targetSnapshotted,
            .targetPasteCommandRejected,
            .pasteDispatchFailed,
            .clipboardRetainedForManualPaste,
        ])
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(pasteboard.string(forType: .string) == "Quill output")
    }

    @Test("paste arms restoration before completion bookkeeping and settles afterward")
    func pasteRestorationOwnsCriticalPath() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let events = await withCheckedContinuation { continuation in
            var events: [String] = []
            PasteController.paste(
                text: "dictated text",
                pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                targetApplicationProvider: { nil },
                simulatePasteAction: { _ in true },
                onPasteFinished: { _ in
                    events.append("completion_bookkeeping")
                },
                onClipboardSettled: {
                    events.append("clipboard_settled")
                    continuation.resume(returning: events)
                },
                onLifecycleEvent: { event in
                    events.append(event.rawValue)
                }
            )
        }

        #expect(events == [
            "clipboard_snapshot_begun",
            "clipboard_snapshot_completed",
            "clipboard_staged",
            "target_snapshotted",
            "paste_dispatched",
            "clipboard_restore_scheduled",
            "completion_bookkeeping",
            "clipboard_restored",
            "clipboard_settled",
        ])
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("paste lifecycle diagnostics expose only fixed content-free categories")
    func lifecycleDiagnosticsAreContentFree() {
        #expect(PasteController.LifecycleEvent.allCases.map(\.rawValue) == [
            "clipboard_snapshot_begun",
            "clipboard_snapshot_completed",
            "clipboard_snapshot_timed_out",
            "clipboard_staged",
            "clipboard_stage_failed",
            "target_snapshotted",
            "target_paste_command_dispatched",
            "target_paste_command_unavailable",
            "target_paste_command_rejected",
            "paste_dispatched",
            "paste_dispatch_failed",
            "paste_dispatch_cancelled",
            "clipboard_ownership_lost",
            "clipboard_restore_scheduled",
            "clipboard_restored",
            "clipboard_restore_skipped",
            "clipboard_retained_for_manual_paste",
        ])
    }

    @Test("dictation paste skips Cmd+V and attribution after clipboard ownership changes")
    func dictationPasteSkipsDispatchAfterClipboardOwnershipChanges() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let events = await withCheckedContinuation { continuation in
            var events: [String] = []
            PasteController.paste(
                text: "dictated text",
                pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                requireStagedClipboardOwnership: true,
                targetApplicationProvider: {
                    events.append("snapshot")
                    pasteboard.clearContents()
                    pasteboard.setString("user-copied-during-delay", forType: .string)
                    return NSRunningApplication.current
                },
                simulatePasteAction: { _ in
                    events.append("command")
                    return true
                },
                onPasteFinished: { application in
                    events.append(application == nil ? "unattributed" : "attributed")
                    continuation.resume(returning: events)
                }
            )
        }

        #expect(events == ["snapshot", "unattributed"])
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(pasteboard.string(forType: .string) == "user-copied-during-delay")
    }

    @Test("shared paste remains ungated unless clipboard ownership is required")
    func sharedPasteRemainsUngatedByDefault() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let events = await withCheckedContinuation { continuation in
            var events: [String] = []
            PasteController.paste(
                text: "pasted text",
                pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                targetApplicationProvider: {
                    events.append("snapshot")
                    pasteboard.clearContents()
                    pasteboard.setString("newer-clipboard-content", forType: .string)
                    return NSRunningApplication.current
                },
                simulatePasteAction: { _ in
                    events.append("command")
                    return true
                },
                onPasteFinished: { _ in
                    events.append("callback")
                    continuation.resume(returning: events)
                }
            )
        }

        #expect(events == ["snapshot", "command", "callback"])
        #expect(pasteboard.string(forType: .string) == "newer-clipboard-content")
    }

    @Test("paste completes without attribution when Cmd+V setup fails")
    func pasteFailureRemainsUnattributed() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let application = await withCheckedContinuation { continuation in
            PasteController.paste(
                text: "dictated text",
                pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                targetApplicationProvider: { NSRunningApplication.current },
                simulatePasteAction: { _ in false },
                onPasteFinished: { continuation.resume(returning: $0) }
            )
        }

        #expect(application == nil)
        let restored = await waitForClipboardString(in: pasteboard, expected: "original")
        #expect(restored == "original")
    }

    @Test("paste restores clipboard after delay")
    func pasteRestoresClipboard() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("user-copied-text", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(), simulatePasteAction: { _ in true })
        _ = await waitForClipboardString(in: pasteboard, expected: "dictated text")

        let restored = await waitForClipboardString(in: pasteboard, expected: "user-copied-text")

        #expect(restored == "user-copied-text")
    }

    @Test("paste restores empty clipboard state")
    func pasteRestoresEmptyClipboard() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(), simulatePasteAction: { _ in true })
        _ = await waitForClipboardString(in: pasteboard, expected: "dictated text")

        let restored = await waitForClipboardString(in: pasteboard, expected: nil)

        #expect(restored == nil)
    }

    @Test("paste restores multi-item clipboard")
    func pasteRestoresMultiItemClipboard() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        // Write two distinct items to the clipboard (e.g., Finder multi-file copy)
        let item1 = NSPasteboardItem()
        item1.setString("item-one", forType: .string)
        let item2 = NSPasteboardItem()
        item2.setString("item-two", forType: .string)
        pasteboard.writeObjects([item1, item2])

        let countBefore = pasteboard.pasteboardItems?.count ?? 0
        #expect(countBefore == 2)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(), simulatePasteAction: { _ in true })
        _ = await waitForClipboardString(in: pasteboard, expected: "dictated text")

        let (countAfter, texts) = await waitForClipboardItems(
            in: pasteboard,
            expectedCount: 2,
            expectedStrings: ["item-one", "item-two"]
        )

        #expect(countAfter == 2)
        #expect(texts == ["item-one", "item-two"])
    }

    @Test("stale paste restore does not overwrite newer clipboard contents")
    func stalePasteRestoreDoesNotOverwriteNewerClipboardContents() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(), simulatePasteAction: { _ in true })
        try await Task.sleep(nanoseconds: 100_000_000)

        pasteboard.clearContents()
        pasteboard.setString("user-copied-after-paste", forType: .string)

        try await Task.sleep(nanoseconds: 700_000_000)

        #expect(pasteboard.string(forType: .string) == "user-copied-after-paste")
    }

    @Test("blocked snapshots time out without blocking main or accepting late data")
    func blockedSnapshotIsBounded() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        let gate = DispatchSemaphore(value: 0)
        let worker = PasteController.ClipboardSnapshotWorker(timeout: 0.03) { _, _ in
            gate.wait() // deliberately noncooperative: cancellation cannot unblock this
            return .init(items: [[(NSPasteboard.PasteboardType.string.rawValue, Data("late".utf8))]])
        }
        defer { gate.signal() }
        var events: [PasteController.LifecycleEvent] = []
        var finished = 0
        var settled = 0
        var commands = 0
        PasteController.paste(
            text: "dictated", pasteboard: pasteboard, snapshotWorker: worker,
            requireStagedClipboardOwnership: true,
            simulatePasteAction: { _ in commands += 1; return true },
            onPasteFinished: { _ in finished += 1 },
            onClipboardSettled: { settled += 1 },
            onLifecycleEvent: { events.append($0) }
        )
        // A main-queue heartbeat executes while the worker is still blocked.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(commands == 1)
        #expect(finished == 1)
        #expect(events.contains(.clipboardSnapshotTimedOut))
        #expect(!events.contains(.clipboardSnapshotCompleted))
        pasteboard.clearContents()
        pasteboard.setString("newer", forType: .string)
        gate.signal()
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(pasteboard.string(forType: .string) == "newer")
        #expect(finished == 1)
        #expect(settled == 1)
        #expect(!events.contains(.clipboardSnapshotCompleted))
    }

    @Test("overlapping pastes share one blocked worker and only the newest stages")
    func overlappingSnapshotsStayBounded() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let worker = PasteController.ClipboardSnapshotWorker(timeout: 0.03) { _, _ in
            started.signal()
            gate.wait()
            return .init(items: [])
        }
        defer { gate.signal() }
        var finished = 0
        var settled = 0
        var commands: [Int] = []
        for index in 0..<25 {
            PasteController.paste(
                text: "dictation-\(index)", pasteboard: pasteboard, snapshotWorker: worker,
                simulatePasteAction: { _ in commands.append(index); return true },
                onPasteFinished: { _ in finished += 1 },
                onClipboardSettled: { settled += 1 }
            )
        }
        try await Task.sleep(nanoseconds: 750_000_000)
        #expect(takeAvailableSignal(started))
        #expect(!takeAvailableSignal(started))
        #expect(commands == [24])
        #expect(finished == 25)
        #expect(settled == 25)
        #expect(pasteboard.string(forType: .string) == "dictation-24")
        gate.signal()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(finished == 25)
        #expect(settled == 25)
        #expect(pasteboard.string(forType: .string) == "dictation-24")
    }

    @Test("cancellation or ownership loss during snapshot prevents delayed staging")
    func snapshotRechecksCancellationAndOwnership() async throws {
        for cancel in [true, false] {
            let pasteboard = makePasteboard()
            pasteboard.setString("original", forType: .string)
            let gate = DispatchSemaphore(value: 0)
            let worker = PasteController.ClipboardSnapshotWorker(timeout: 0.03) { _, _ in
                gate.wait()
                return .init(items: [])
            }
            var allowed = true
            var commands = 0
            var finished = 0
            var settled = 0
            PasteController.paste(
                text: "obsolete", pasteboard: pasteboard, snapshotWorker: worker,
                shouldDispatchPaste: { allowed },
                simulatePasteAction: { _ in commands += 1; return true },
                onPasteFinished: { _ in finished += 1 },
                onClipboardSettled: { settled += 1 }
            )
            if cancel {
                allowed = false
            } else {
                pasteboard.clearContents()
                pasteboard.setString("user-copy", forType: .string)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(commands == 0)
            #expect(finished == 1)
            #expect(settled == 1)
            #expect(pasteboard.string(forType: .string) == (cancel ? "original" : "user-copy"))
            gate.signal()
            try await Task.sleep(nanoseconds: 30_000_000)
            #expect(finished == 1)
            #expect(settled == 1)
        }
    }

    @Test("overlapping staged pastes restore the original clipboard and dispatch only the latest")
    func overlappingStagedPastesKeepOriginalSnapshot() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        var commands: [String] = []
        var finished = 0
        var settled = 0
        PasteController.paste(
            text: "first", pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
            simulatePasteAction: { _ in commands.append("first"); return true },
            onPasteFinished: { _ in finished += 1 },
            onClipboardSettled: { settled += 1 },
            onLifecycleEvent: { event in
                if event == .clipboardStaged {
                    PasteController.paste(
                        text: "second", pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                        simulatePasteAction: { _ in commands.append("second"); return true },
                        onPasteFinished: { _ in finished += 1 },
                        onClipboardSettled: { settled += 1 }
                    )
                }
            }
        )
        try await Task.sleep(nanoseconds: 850_000_000)
        #expect(commands == ["second"])
        #expect(finished == 2)
        #expect(settled == 2)
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("snapshot restores multiple items and formats after dispatch")
    func snapshotRestoresAllFormats() async {
        let pasteboard = makePasteboard()
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        let richData = Data("{\\rtf1 example}".utf8)
        first.setData(richData, forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        pasteboard.writeObjects([first, second])
        var commands = 0
        await withCheckedContinuation { continuation in
            PasteController.paste(
                text: "dictated", pasteboard: pasteboard, snapshotWorker: makeTestClipboardSnapshotWorker(),
                simulatePasteAction: { _ in
                    #expect(pasteboard.string(forType: .string) == "dictated")
                    commands += 1
                    return true
                },
                onClipboardSettled: { continuation.resume() }
            )
        }
        #expect(commands == 1)
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "first")
        #expect(items.first?.data(forType: .rtf) == richData)
        #expect(items.last?.string(forType: .string) == "second")
    }

    /// Immediate polling never blocks the test's actor waiting for a worker.
    private func takeAvailableSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    @Test("snapshot helper rejects a stale named-pasteboard generation")
    func helperRejectsStaleGeneration() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("before", forType: .string)
        let oldCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("after", forType: .string)
        let worker = makeTestClipboardSnapshotWorker()
        let result = await withCheckedContinuation { continuation in
            worker.snapshot(name: pasteboard.name.rawValue, changeCount: oldCount) { snapshot, timedOut in
                continuation.resume(returning: (snapshot, timedOut))
            }
        }
        #expect(result.0 == nil)
        #expect(!result.1)
        #expect(pasteboard.string(forType: .string) == "after")
    }

    private func makePasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("com.muesli.tests.PasteController.\(UUID().uuidString)")
        return NSPasteboard(name: name)
    }

    private func waitForClipboardString(in pasteboard: NSPasteboard, expected: String?) async -> String? {
        await withCheckedContinuation { continuation in
            let deadline = Date().addingTimeInterval(clipboardRestoreTimeout)
            var poll: (() -> Void)?
            poll = {
                let current = pasteboard.string(forType: .string)
                if current == expected || Date() >= deadline {
                    continuation.resume(returning: current)
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + clipboardPollInterval) {
                    poll?()
                }
            }

            DispatchQueue.main.async {
                poll?()
            }
        }
    }

    private func waitForClipboardItems(
        in pasteboard: NSPasteboard,
        expectedCount: Int,
        expectedStrings: [String]
    ) async -> (Int, [String]) {
        await withCheckedContinuation { continuation in
            let deadline = Date().addingTimeInterval(clipboardRestoreTimeout)
            var poll: (() -> Void)?
            poll = {
                let items = pasteboard.pasteboardItems ?? []
                let count = items.count
                let strings = items.compactMap { $0.string(forType: .string) }
                if (count == expectedCount && strings == expectedStrings) || Date() >= deadline {
                    continuation.resume(returning: (count, strings))
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + clipboardPollInterval) {
                    poll?()
                }
            }

            DispatchQueue.main.async {
                poll?()
            }
        }
    }
}

private final class ClipboardSnapshotTestBundle: NSObject {}

@MainActor
func makeTestClipboardSnapshotWorker() -> PasteController.ClipboardSnapshotWorker {
    // The helper is an exact sibling SwiftPM product. Never use PATH or the
    // installed release, which may not implement this private IPC endpoint.
    let testBundle = Bundle(for: ClipboardSnapshotTestBundle.self)
    let candidates = [
        testBundle.bundleURL.deletingLastPathComponent().appendingPathComponent("muesli-cli"),
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("muesli-cli"),
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("muesli-cli"),
    ].compactMap { $0 }
    let helper = candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    #expect(helper != nil, "Build the muesli-cli product alongside the test bundle")
    return PasteController.ClipboardSnapshotWorker(helperURL: helper)
}
