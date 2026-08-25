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

    @Test("paste with empty string is a no-op")
    func pasteEmptyIsNoOp() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "", pasteboard: pasteboard, simulatePasteAction: { true })

        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test("paste temporarily writes text to clipboard for Cmd+V")
    func pasteWritesTextToClipboard() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })

        // Immediately after paste(), the clipboard holds the dictation text
        // (restoration happens asynchronously after ~500ms)
        #expect(pasteboard.string(forType: .string) == "dictated text")

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
                pasteboard: pasteboard,
                requireStagedClipboardOwnership: true,
                shouldDispatchPaste: { false },
                simulatePasteAction: {
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
        var lifecycleEvents: [PasteController.LifecycleEvent] = []

        let result = await withCheckedContinuation { continuation in
            PasteController.paste(
                text: "Quill output",
                pasteboard: pasteboard,
                requireStagedClipboardOwnership: true,
                shouldDispatchPaste: { false },
                retainStagedTextOnFailure: true,
                onPasteFinished: { application in
                    continuation.resume(returning: application)
                },
                onLifecycleEvent: { lifecycleEvents.append($0) }
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
                pasteboard: pasteboard,
                targetApplicationProvider: {
                    events.append("snapshot")
                    return expectedApplication
                },
                simulatePasteAction: {
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
                pasteboard: successfulPasteboard,
                simulatePasteAction: {
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
                pasteboard: failedPasteboard,
                simulatePasteAction: {
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
                targetApplicationProvider: { expectedApplication },
                dispatchStrategy: .targetApplicationPasteCommand,
                targetPasteAction: { application in
                    #expect(application.processIdentifier == expectedApplication.processIdentifier)
                    return true
                },
                simulatePasteAction: {
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
                pasteboard: pasteboard,
                targetApplicationProvider: { NSRunningApplication.current },
                dispatchStrategy: .targetApplicationPasteCommand,
                retainStagedTextOnFailure: true,
                targetPasteAction: { _ in false },
                simulatePasteAction: {
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
                pasteboard: pasteboard,
                targetApplicationProvider: { nil },
                simulatePasteAction: { true },
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
                pasteboard: pasteboard,
                requireStagedClipboardOwnership: true,
                targetApplicationProvider: {
                    events.append("snapshot")
                    pasteboard.clearContents()
                    pasteboard.setString("user-copied-during-delay", forType: .string)
                    return NSRunningApplication.current
                },
                simulatePasteAction: {
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
                pasteboard: pasteboard,
                targetApplicationProvider: {
                    events.append("snapshot")
                    pasteboard.clearContents()
                    pasteboard.setString("newer-clipboard-content", forType: .string)
                    return NSRunningApplication.current
                },
                simulatePasteAction: {
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
                pasteboard: pasteboard,
                targetApplicationProvider: { NSRunningApplication.current },
                simulatePasteAction: { false },
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

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })

        let restored = await waitForClipboardString(in: pasteboard, expected: "user-copied-text")

        #expect(restored == "user-copied-text")
    }

    @Test("paste restores empty clipboard state")
    func pasteRestoresEmptyClipboard() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })

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

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })

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

        PasteController.paste(text: "dictated text", pasteboard: pasteboard, simulatePasteAction: { true })
        try await Task.sleep(nanoseconds: 100_000_000)

        pasteboard.clearContents()
        pasteboard.setString("user-copied-after-paste", forType: .string)

        try await Task.sleep(nanoseconds: 700_000_000)

        #expect(pasteboard.string(forType: .string) == "user-copied-after-paste")
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
