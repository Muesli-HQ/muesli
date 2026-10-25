import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Live dictation final paste")
@MainActor
struct LiveDictationFinalPasteTests {
    private typealias Paste = LiveDictationFinalPaste

    @Test("snapshot preserves every item and representation, including empty binary data")
    func completeSnapshot() {
        let original = FakeClipboard.original
        let snapshot = Paste.materialize(generation: { 7 }, items: { original.map { $0.map(\.type) } }, data: { index, type in
            original[index].first { $0.type == type }?.data
        })
        #expect(snapshot == Paste.Snapshot(generation: 7, items: original))
        #expect(Paste.materialize(generation: { 1 }, items: { [] }, data: { _, _ in nil })?.items == [])
    }

    @Test("missing representations and generation changes invalidate the entire snapshot")
    func incompleteSnapshot() {
        #expect(Paste.materialize(generation: { 1 }, items: { [["text", "image"]] }, data: { _, type in
            type == "text" ? Data("old".utf8) : nil
        }) == nil)
        #expect(Paste.materialize(generation: { 1 }, items: { [[]] }, data: { _, _ in Data() }) == nil)
        var generation = 1
        #expect(Paste.materialize(generation: { generation }, items: { [["text"]] }, data: { _, _ in
            generation += 1
            return Data("old".utf8)
        }) == nil)
    }

    @Test("one marked Command-V pair targets the captured PID and restores every flavor only after ACK")
    func acknowledgedPaste() async {
        let fake = FakeClipboard()
        let text = "e\u{301} café 👩🏽‍💻 你好"
        let success = await fake.perform(text: text) {
            #expect(fake.posts.count == 2)
            #expect(fake.restores == 0)
            #expect(fake.items.first?.first?.data == Data(text.utf8))
            return true
        }
        #expect(success)
        #expect(fake.stages == 1)
        #expect(fake.restores == 1)
        #expect(fake.items == FakeClipboard.original)
        #expect(fake.posts.map(\.pid) == [42, 42])
        #expect(fake.posts.map(\.type) == [.keyDown, .keyUp])
        for posted in fake.posts {
            #expect(posted.flags == .maskCommand)
            #expect(posted.keyCode == 9)
            #expect(posted.repeatCount == 0)
            #expect(posted.marker == MuesliSyntheticKeyboardEvent.userDataMarker)
        }
    }

    @Test("keyup still targets the captured PID when focus changes after keydown")
    func pairCannotBeSplit() async {
        let fake = FakeClipboard()
        fake.afterDown = { fake.targetValid = false }
        #expect(!(await fake.perform(acknowledge: { false })))
        #expect(fake.posts.map(\.pid) == [42, 42])
        #expect(fake.posts.map(\.type) == [.keyDown, .keyUp])
        #expect(fake.restores == 0)
    }

    @Test("serialized live replacements restore all clipboard flavors between acknowledged operations")
    func serializedAcknowledgedOperations() async {
        let fake = FakeClipboard()
        let texts = ["first", " second", " café 👩🏽‍💻"]
        let acknowledgements = AsyncStream<Int>.makeStream()
        var permits: [Int: CheckedContinuation<Bool, Never>] = [:]
        var snapshots: [Paste.Snapshot] = []
        var access = fake.access()
        access.snapshot = {
            let snapshot = Paste.Snapshot(generation: fake.generation, items: fake.items)
            snapshots.append(snapshot)
            return snapshot
        }
        let operation = Task { @MainActor in
            var results: [Bool] = []
            for (index, text) in texts.enumerated() {
                results.append(await fake.perform(text: text, access: access) {
                    await withCheckedContinuation { continuation in
                        permits[index] = continuation
                        acknowledgements.continuation.yield(index)
                    }
                })
            }
            return results
        }
        var iterator = acknowledgements.stream.makeAsyncIterator()
        for index in texts.indices {
            #expect(await iterator.next() == index)
            // The payload stays available until this exact operation is ACKed.
            // The caller must not overlap another stage while awaiting that ACK.
            await Task.yield()
            #expect(fake.stages == index + 1)
            #expect(fake.posts.count == (index + 1) * 2)
            #expect(fake.restores == index)
            #expect(fake.items.first?.first?.data == Data(texts[index].utf8))
            #expect(snapshots.count == index + 1)
            #expect(snapshots.last?.items == FakeClipboard.original)
            permits.removeValue(forKey: index)?.resume(returning: true)
        }
        #expect(await operation.value == [true, true, true])
        #expect(snapshots.map(\.generation) == [1, 3, 5])
        #expect(fake.restores == texts.count)
        #expect(fake.items == FakeClipboard.original)
        #expect(fake.ownership == nil)
        #expect(fake.posts.map(\.pid) == Array(repeating: 42, count: 6))
        #expect(fake.posts.map(\.type) == [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp])
    }

    @Test("a copy between live replacements becomes the next operation's restoration baseline")
    func externalCopyBetweenOperations() async {
        let fake = FakeClipboard()
        #expect(await fake.perform(text: "first"))
        #expect(fake.items == FakeClipboard.original)
        fake.externalCopy()
        let copiedGeneration = fake.generation
        var snapshots: [Paste.Snapshot] = []
        var access = fake.access()
        access.snapshot = {
            let saved = Paste.Snapshot(generation: fake.generation, items: fake.items)
            snapshots.append(saved)
            return saved
        }
        for (index, text) in [" next", " last"].enumerated() {
            let acknowledged = await fake.perform(text: text, access: access) {
                #expect(fake.restores == index + 1)
                #expect(fake.items.first?.first?.data == Data(text.utf8))
                return true
            }
            #expect(acknowledged)
            #expect(fake.items == FakeClipboard.newer)
            #expect(fake.ownership == nil)
        }
        #expect(snapshots.map(\.items) == [FakeClipboard.newer, FakeClipboard.newer])
        #expect(snapshots.map(\.generation) == [copiedGeneration, copiedGeneration + 2])
        #expect(fake.stages == 3)
        #expect(fake.restores == 3)
        #expect(fake.posts.count == 6)
    }

    @Test("unacknowledged dispatch retains payload for a delayed consumer")
    func failedAcknowledgement() async {
        let fake = FakeClipboard()
        #expect(!(await fake.perform(acknowledge: { false })))
        #expect(fake.posts.count == 2)
        #expect(fake.restores == 0)
        #expect(fake.items.first?.first?.data == Data("final".utf8))
        #expect(fake.diagnostics.contains("final_paste_unacknowledged_clipboard_retained"))
    }

    @Test("new clipboard content during acknowledgement is never overwritten")
    func newerClipboardWins() async {
        let fake = FakeClipboard()
        #expect(await fake.perform {
            fake.externalCopy()
            return true
        })
        #expect(fake.restores == 0)
        #expect(fake.items == FakeClipboard.newer)
    }

    @Test("snapshot failure or staleness causes no clipboard mutation", arguments: [0, 1, 2, 3])
    func snapshotPreflight(mode: Int) async {
        let fake = FakeClipboard()
        var access = fake.access()
        access.snapshot = {
            let saved = Paste.Snapshot(generation: fake.generation, items: fake.items)
            switch mode {
            case 0: return nil
            case 1: fake.externalCopy()
            case 2: fake.targetValid = false
            default: fake.layoutValid = false
            }
            return saved
        }
        #expect(!(await fake.perform(access: access)))
        #expect(fake.stages == 0)
        #expect(fake.restores == 0)
        #expect(fake.posts.isEmpty)
    }

    @Test("failed staging restores only the owned generation", arguments: [false, true])
    func failedStage(newerCopy: Bool) async {
        let fake = FakeClipboard()
        fake.stageSucceeds = false
        if newerCopy { fake.afterStage = { fake.externalCopy() } }
        #expect(!(await fake.perform()))
        #expect(fake.posts.isEmpty)
        #expect(fake.restores == (newerCopy ? 0 : 1))
        #expect(fake.items == (newerCopy ? FakeClipboard.newer : FakeClipboard.original))
    }

    @Test("post-stage target, layout, or clipboard changes prevent dispatch", arguments: [0, 1, 2])
    func changedAfterStage(mode: Int) async {
        let fake = FakeClipboard()
        fake.afterStage = {
            switch mode {
            case 0: fake.targetValid = false
            case 1: fake.layoutValid = false
            default: fake.externalCopy()
            }
        }
        #expect(!(await fake.perform()))
        #expect(fake.posts.isEmpty)
        #expect(fake.restores == (mode == 2 ? 0 : 1))
        #expect(fake.items == (mode == 2 ? FakeClipboard.newer : FakeClipboard.original))
    }

    @Test("empty text and controls cannot stage or submit", arguments: ["", "a\nb", "\t", "\r", "\u{85}", "\u{2028}", "\u{2029}"])
    func invalidText(text: String) async {
        let fake = FakeClipboard()
        #expect(!(await fake.perform(text: text)))
        #expect(fake.stages == 0)
        #expect(fake.posts.isEmpty)
    }

    @Test("event allocation failure occurs before any clipboard work")
    func eventAllocationFailure() async {
        let fake = FakeClipboard()
        var access = fake.access()
        access.createEvents = { nil }
        access.snapshot = { Issue.record("snapshot must not start"); return nil }
        #expect(!(await fake.perform(access: access)))
        #expect(fake.stages == 0)
    }

    @Test("snapshot deadline ignores a late provider without waiting for it")
    func snapshotTimeout() async {
        let fake = FakeClipboard()
        var access = fake.access()
        var provider: CheckedContinuation<Paste.Snapshot?, Never>?
        access.snapshot = { await withCheckedContinuation { provider = $0 } }
        access.snapshotTimeout = .milliseconds(20)
        #expect(!(await fake.perform(access: access)))
        #expect(provider != nil)
        provider?.resume(returning: .init(generation: fake.generation, items: fake.items))
        await Task.yield()
        #expect(fake.stages == 0)
        #expect(fake.posts.isEmpty)
    }

    @Test("cancellation returns while the provider is blocked and ignores its late result")
    func cancellationDuringSnapshot() async {
        let fake = FakeClipboard()
        let started = AsyncStream<Void>.makeStream()
        var access = fake.access()
        var provider: CheckedContinuation<Paste.Snapshot?, Never>?
        access.snapshot = {
            await withCheckedContinuation { provider = $0; started.continuation.yield() }
        }
        let operation = Task { await fake.perform(access: access) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        operation.cancel()
        #expect(!(await operation.value))
        provider?.resume(returning: .init(generation: fake.generation, items: fake.items))
        await Task.yield()
        #expect(fake.stages == 0)
        #expect(fake.posts.isEmpty)
    }

    @Test("cancellation before dispatch restores staging; cancellation after dispatch retains it")
    func cancellationOrdering() async {
        let before = FakeClipboard()
        before.afterStage = { withUnsafeCurrentTask { $0?.cancel() } }
        let beforeTask = Task { await before.perform() }
        #expect(!(await beforeTask.value))
        #expect(before.posts.isEmpty)
        #expect(before.restores == 1)

        let after = FakeClipboard()
        let afterTask = Task {
            await after.perform {
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            }
        }
        #expect(!(await afterTask.value))
        #expect(after.posts.count == 2)
        #expect(after.restores == 0)
    }

    @MainActor
    private final class FakeClipboard {
        static let original: [[Paste.Flavor]] = [
            [.init(type: "public.utf8-plain-text", data: Data("prior".utf8)),
             .init(type: "public.rtf", data: Data([0, 255, 17]))],
            [.init(type: "public.png", data: Data([137, 80, 78, 71])),
             .init(type: "custom.empty", data: Data())]
        ]
        static let newer: [[Paste.Flavor]] = [[.init(type: "other", data: Data("new copy".utf8))]]
        struct Posted {
            let pid: pid_t
            let type: CGEventType
            let flags: CGEventFlags
            let keyCode: Int64
            let repeatCount: Int64
            let marker: Int64
        }
        var generation = 1
        var items = original
        var ownership: Paste.Ownership?
        var stages = 0
        var restores = 0
        var posts: [Posted] = []
        var diagnostics: [String] = []
        var targetValid = true
        var layoutValid = true
        var stageSucceeds = true
        var afterStage: (() -> Void)?
        var afterDown: (() -> Void)?

        func externalCopy() {
            generation += 1
            items = Self.newer
            ownership = nil
        }

        func access() -> Paste.Access {
            Paste.Access(snapshot: { .init(generation: self.generation, items: self.items) },
                generation: { self.generation }, stage: { text, expected in
                    guard self.generation == expected else { return .init(succeeded: false, ownership: nil) }
                    self.stages += 1
                    self.generation += 1
                    self.items = [[.init(type: "public.utf8-plain-text", data: Data(text.utf8))]]
                    let owner = Paste.Ownership(generation: self.generation, marker: Data([1]))
                    self.ownership = owner
                    self.afterStage?()
                    return .init(succeeded: self.stageSucceeds, ownership: owner)
                }, owns: { self.ownership == $0 && self.generation == $0.generation },
                restore: { snapshot, owner in
                    guard self.ownership == owner, self.generation == owner.generation else { return false }
                    self.restores += 1
                    self.items = snapshot.items
                    self.generation += 1
                    self.ownership = nil
                    return true
                }, createEvents: { Paste.makeEvents(keyCode: 9) },
                processIsCurrent: { _ in self.targetValid }, post: { event, pid in
                    self.posts.append(.init(pid: pid, type: event.type, flags: event.flags,
                        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                        repeatCount: event.getIntegerValueField(.keyboardEventAutorepeat),
                        marker: event.getIntegerValueField(.eventSourceUserData)))
                    if event.type == .keyDown { self.afterDown?() }
                }, eventsAreCurrent: { _ in self.layoutValid })
        }

        func perform(text: String = "final", access: Paste.Access? = nil,
                     acknowledge: @escaping () async -> Bool = { true }) async -> Bool {
            await Paste.perform(text: text, to: 42, validateTarget: { self.targetValid },
                acknowledge: acknowledge, onDiagnostic: { self.diagnostics.append($0) },
                access: access ?? self.access())
        }
    }
}
