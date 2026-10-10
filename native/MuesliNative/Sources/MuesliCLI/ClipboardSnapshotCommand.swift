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

    mutating func run() async throws {
        var outputStatus = stat()
        guard fstat(STDOUT_FILENO, &outputStatus) == 0,
              outputStatus.st_mode & S_IFMT == S_IFIFO else { Foundation.exit(1) }
        let name = pasteboardName
        let expectedCount = changeCount
        let snapshot = await MainActor.run {
            // Readiness means the helper's main actor is actually running, not
            // merely that dyld or ArgumentParser has started the process.
            guard Thread.isMainThread else { return nil as ClipboardSnapshotPayload? }
            do {
                try FileHandle.standardOutput.write(contentsOf: ClipboardSnapshotTransport.ready)
            } catch { return nil }
            guard let snapshot = Self.snapshot(name: name, expectedCount: expectedCount) else { return nil }
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
