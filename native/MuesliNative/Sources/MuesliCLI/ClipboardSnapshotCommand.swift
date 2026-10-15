import AppKit
import ArgumentParser
import Foundation
import MuesliCore
import Darwin

/// Private IPC endpoint for the app. Clipboard bytes go only to the parent's
/// anonymous stdout pipe, never to diagnostics, a file, or the normal CLI envelope.
struct ClipboardSnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clipboard-snapshot",
        abstract: "Internal clipboard snapshot helper.",
        shouldDisplay: false
    )

    @Option var pasteboardName: String
    @Option var changeCount: Int
    @Flag var waitForCopy = false

    mutating func run() async throws {
        var outputStatus = stat()
        guard fstat(STDOUT_FILENO, &outputStatus) == 0,
              outputStatus.st_mode & S_IFMT == S_IFIFO else { Foundation.exit(1) }
        let name = pasteboardName
        let expectedCount = changeCount
        let readCopiedSelection = waitForCopy
        let snapshot = await MainActor.run {
            // Readiness means the helper's main actor is actually running, not
            // merely that dyld or ArgumentParser has started the process.
            guard Thread.isMainThread else { return nil as ClipboardSnapshotPayload? }
            do {
                try FileHandle.standardOutput.write(contentsOf: ClipboardSnapshotTransport.ready)
            } catch { return nil }
            let result = readCopiedSelection
                ? Self.copiedSelection(name: name, originalCount: expectedCount)
                : Self.snapshot(name: name, expectedCount: expectedCount)
            guard let snapshot = result else { return nil }
            do {
                try FileHandle.standardOutput.write(contentsOf: Data([ClipboardSnapshotTransport.payloadReady]))
            } catch { return nil }
            return snapshot
        }
        guard let snapshot else { Foundation.exit(1) }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let output = try encoder.encode(snapshot)
            guard output.count <= ClipboardSnapshotTransport.maximumWireBytes else { Foundation.exit(1) }
            try FileHandle.standardOutput.write(contentsOf: output)
        } catch {
            Foundation.exit(1)
        }
    }

    /// The app posts Copy only after receiving readiness. All clipboard reads
    /// remain on this helper's main thread and the parent bounds each phase.
    @MainActor
    private static func copiedSelection(name: String, originalCount: Int) -> ClipboardSnapshotPayload? {
        guard Thread.isMainThread else { return nil }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        let deadline = Date().addingTimeInterval(ClipboardSnapshotTransport.copyWaitTimeout)
        while pasteboard.changeCount == originalCount, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.005)))
        }
        let copiedCount = pasteboard.changeCount
        guard copiedCount != originalCount else { return nil }
        do {
            try FileHandle.standardOutput.write(contentsOf: Data([ClipboardSnapshotTransport.selectionReadStarted]))
        } catch { return nil }
        guard let text = pasteboard.string(forType: .string),
              pasteboard.changeCount == copiedCount else { return nil }
        let data = Data(text.utf8)
        guard data.count <= ClipboardSnapshotTransport.maximumSelectionBytes else { return nil }
        return ClipboardSnapshotPayload(changeCount: copiedCount, items: [[
            .init(type: NSPasteboard.PasteboardType.string.rawValue, data: data),
        ]])
    }

    @MainActor
    private static func snapshot(name: String, expectedCount: Int) -> ClipboardSnapshotPayload? {
        guard Thread.isMainThread else { return nil }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        guard pasteboard.changeCount == expectedCount else { return nil }
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= ClipboardSnapshotTransport.maximumItems else { return nil }
        var saved: [[ClipboardSnapshotPayload.Flavor]] = []
        var totalBytes = 0
        for item in items {
            guard item.types.count <= ClipboardSnapshotTransport.maximumFlavorsPerItem else { return nil }
            var flavors: [ClipboardSnapshotPayload.Flavor] = []
            for type in item.types {
                guard type.rawValue.utf8.count <= ClipboardSnapshotTransport.maximumTypeBytes else { return nil }
                if let data = item.data(forType: type) {
                    totalBytes += data.count
                    guard totalBytes <= ClipboardSnapshotTransport.maximumDataBytes else { return nil }
                    flavors.append(.init(type: type.rawValue, data: data))
                }
                guard pasteboard.changeCount == expectedCount else { return nil }
            }
            if !flavors.isEmpty { saved.append(flavors) }
        }
        guard pasteboard.changeCount == expectedCount else { return nil }
        return ClipboardSnapshotPayload(changeCount: expectedCount, items: saved)
    }
}
