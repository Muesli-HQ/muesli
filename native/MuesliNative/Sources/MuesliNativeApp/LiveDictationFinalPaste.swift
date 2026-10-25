import AppKit

/// A guarded plain-text replacement used by bounded live updates and final
/// cleanup, after the target has selected and acknowledged its owned range.
/// Clipboard ownership never substitutes for target readback.
enum LiveDictationFinalPaste {
    struct Flavor: Sendable, Equatable {
        let type: String
        let data: Data
    }
    struct Snapshot: Sendable, Equatable {
        let generation: Int
        let items: [[Flavor]]
    }
    struct Ownership: Equatable {
        let generation: Int
        let marker: Data?
    }
    struct StageResult {
        let succeeded: Bool
        let ownership: Ownership?
    }
    struct EventPair {
        let down: CGEvent
        let up: CGEvent
    }

    @MainActor
    struct Access {
        var snapshot: () async -> Snapshot?
        var generation: () -> Int
        var stage: (String, Int) -> StageResult
        var owns: (Ownership) -> Bool
        var restore: (Snapshot, Ownership) -> Bool
        var createEvents: () -> EventPair?
        var processIsCurrent: (pid_t) -> Bool
        var post: (CGEvent, pid_t) -> Void
        var eventsAreCurrent: (EventPair) -> Bool = { _ in true }
        var snapshotTimeout: Duration = .seconds(1)
    }

    @MainActor
    static func perform(text: String, to pid: pid_t,
                        validateTarget: @escaping () -> Bool,
                        acknowledge: @escaping () async -> Bool,
                        onDiagnostic: @escaping (String) -> Void) async -> Bool {
        await perform(text: text, to: pid, validateTarget: validateTarget,
                      acknowledge: acknowledge, onDiagnostic: onDiagnostic, access: nativeAccess())
    }

    @MainActor
    static func perform(text: String, to pid: pid_t,
                        validateTarget: @escaping () -> Bool,
                        acknowledge: @escaping () async -> Bool,
                        onDiagnostic: @escaping (String) -> Void,
                        access: Access) async -> Bool {
        guard !Task.isCancelled, !text.isEmpty, LiveDictationKeyboardInput.isSupported(text),
              pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            onDiagnostic("final_paste_invalid_request")
            return false
        }
        guard let events = access.createEvents() else {
            onDiagnostic("final_paste_event_creation_failed")
            return false
        }
        guard let saved = await boundedSnapshot(timeout: access.snapshotTimeout, operation: access.snapshot) else {
            onDiagnostic("final_paste_snapshot_incomplete")
            return false
        }
        guard !Task.isCancelled, access.eventsAreCurrent(events), access.processIsCurrent(pid), validateTarget(),
              access.generation() == saved.generation else {
            onDiagnostic("final_paste_preflight_changed")
            return false
        }
        let stage = access.stage(text, saved.generation)
        var dispatched = false
        var acknowledged = false
        defer {
            if let owner = stage.ownership, access.owns(owner) {
                if !dispatched || acknowledged {
                    if !access.restore(saved, owner) { onDiagnostic("final_paste_restore_failed") }
                } else {
                    // A delayed renderer must not read the previous clipboard
                    // as the still-pending paste's payload. No fallback is sent.
                    onDiagnostic("final_paste_unacknowledged_clipboard_retained")
                }
            }
        }
        guard stage.succeeded, let owner = stage.ownership else {
            onDiagnostic("final_paste_stage_failed")
            return false
        }
        guard !Task.isCancelled, access.eventsAreCurrent(events), access.processIsCurrent(pid), validateTarget(), access.owns(owner) else {
            onDiagnostic("final_paste_dispatch_preflight_changed")
            return false
        }
        // No suspension or early return may split the pair. Both always target
        // the captured process, even if focus changes while the event is handled.
        dispatched = true
        access.post(events.down, pid)
        access.post(events.up, pid)
        acknowledged = await acknowledge()
        guard acknowledged, !Task.isCancelled else {
            onDiagnostic("final_paste_not_acknowledged")
            return false
        }
        return true
    }

    /// All advertised representations must materialize within one unchanged
    /// generation. Native callers run this synchronous provider work off-main.
    static func materialize(generation: () -> Int, items: () -> [[String]]?,
                            data: (Int, String) -> Data?) -> Snapshot? {
        let before = generation()
        guard let types = items() else { return nil }
        var saved: [[Flavor]] = []
        for (index, itemTypes) in types.enumerated() {
            guard !itemTypes.isEmpty else { return nil }
            var flavors: [Flavor] = []
            for type in itemTypes {
                guard let bytes = data(index, type) else { return nil }
                flavors.append(.init(type: type, data: bytes))
            }
            saved.append(flavors)
        }
        guard generation() == before else { return nil }
        return Snapshot(generation: before, items: saved)
    }

    private static let ownershipType = NSPasteboard.PasteboardType("com.muesli.live-final-paste-owner")

    /// A blocked external pasteboard provider must not keep finalization waiting.
    /// Unstructured tasks deliberately outlive the deadline; late read-only results
    /// are ignored, and no task-group scope waits for a blocked provider to return.
    @MainActor
    private static func boundedSnapshot(timeout: Duration,
                                        operation: @escaping () async -> Snapshot?) async -> Snapshot? {
        let gate = SnapshotGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                guard !Task.isCancelled else { gate.resolve(nil); return }
                Task { @MainActor in gate.resolve(await operation()) }
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    gate.resolve(nil)
                }
            }
        } onCancel: {
            gate.resolve(nil)
        }
    }

    private final class SnapshotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Snapshot?, Never>?
        private var completed = false
        private var result: Snapshot?
        func install(_ continuation: CheckedContinuation<Snapshot?, Never>) {
            lock.lock()
            if completed {
                let result = result
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
        func resolve(_ result: Snapshot?) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    @MainActor
    private static func nativeAccess() -> Access {
        let board = NSPasteboard.general
        return Access(snapshot: {
            // NSPasteboardItem providers may synchronously perform IPC or fetch
            // promised data. Neither they nor their objects cross to MainActor.
            await Task.detached(priority: .userInitiated) {
                let source = NSPasteboard.general
                var sourceItems: [NSPasteboardItem] = []
                return materialize(generation: { source.changeCount }, items: {
                    if let items = source.pasteboardItems {
                        sourceItems = items
                        return items.map { $0.types.map(\.rawValue) }
                    }
                    return (source.types ?? []).isEmpty ? [] : nil
                }, data: { index, type in
                    sourceItems[index].data(forType: .init(type))
                })
            }.value
        }, generation: { board.changeCount }, stage: { text, expected in
            let marker = Data(UUID().uuidString.utf8)
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string), item.setData(marker, forType: ownershipType),
                  board.changeCount == expected else { return .init(succeeded: false, ownership: nil) }
            let cleared = Ownership(generation: board.clearContents(), marker: nil)
            guard board.changeCount == cleared.generation else { return .init(succeeded: false, ownership: nil) }
            let written = board.writeObjects([item])
            let staged = Ownership(generation: board.changeCount, marker: marker)
            if owns(staged, board: board) { return .init(succeeded: written, ownership: staged) }
            return .init(succeeded: false, ownership: owns(cleared, board: board) ? cleared : nil)
        }, owns: { owns($0, board: board) }, restore: { saved, owner in
            var items: [NSPasteboardItem] = []
            for flavors in saved.items {
                let item = NSPasteboardItem()
                for flavor in flavors {
                    guard item.setData(flavor.data, forType: .init(flavor.type)) else { return false }
                }
                items.append(item)
            }
            guard owns(owner, board: board) else { return false }
            let clearedGeneration = board.clearContents()
            guard board.changeCount == clearedGeneration else { return false }
            return items.isEmpty || board.writeObjects(items)
        }, createEvents: {
            guard let chord = PasteKeyboardLayout.resolve(.automatic), chord.flags == .maskCommand,
                  ![36, 48, 51, 53, 76, 117].contains(chord.keyCode) else { return nil }
            return makeEvents(keyCode: chord.keyCode)
        }, processIsCurrent: { pid in
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } == true
        }, post: { event, pid in event.postToPid(pid) }, eventsAreCurrent: { events in
            guard let chord = PasteKeyboardLayout.resolve(.automatic) else { return false }
            return chord.flags == .maskCommand
                && events.down.getIntegerValueField(.keyboardEventKeycode) == Int64(chord.keyCode)
                && events.up.getIntegerValueField(.keyboardEventKeycode) == Int64(chord.keyCode)
        })
    }

    @MainActor
    private static func owns(_ owner: Ownership, board: NSPasteboard) -> Bool {
        guard board.changeCount == owner.generation else { return false }
        guard let marker = owner.marker else { return true }
        return board.data(forType: ownershipType) == marker && board.changeCount == owner.generation
    }

    static func makeEvents(keyCode: CGKeyCode) -> EventPair? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return nil }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            MuesliSyntheticKeyboardEvent.mark(event)
        }
        return EventPair(down: down, up: up)
    }
}
