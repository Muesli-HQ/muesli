import AppKit
import ArgumentParser
import Foundation
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

    private struct Snapshot: Encodable {
        struct Flavor: Encodable {
            let type: String
            let data: Data
        }
        let changeCount: Int
        let items: [[Flavor]]
    }

    mutating func run() async throws {
        var outputStatus = stat()
        guard fstat(STDOUT_FILENO, &outputStatus) == 0,
              outputStatus.st_mode & S_IFMT == S_IFIFO else { Foundation.exit(1) }
        let name = pasteboardName
        let expectedCount = changeCount
        let output = await MainActor.run { Self.snapshot(name: name, expectedCount: expectedCount) }
        guard let output else { Foundation.exit(1) }
        do {
            try FileHandle.standardOutput.write(contentsOf: output)
        } catch {
            Foundation.exit(1)
        }
    }

    @MainActor
    private static func snapshot(name: String, expectedCount: Int) -> Data? {
        guard Thread.isMainThread else { return nil }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        guard pasteboard.changeCount == expectedCount else { return nil }
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= 128 else { return nil }
        var saved: [[Snapshot.Flavor]] = []
        var totalBytes = 0
        for item in items {
            guard item.types.count <= 64 else { return nil }
            var flavors: [Snapshot.Flavor] = []
            for type in item.types {
                guard type.rawValue.utf8.count <= 1024 else { return nil }
                if let data = item.data(forType: type) {
                    totalBytes += data.count
                    guard totalBytes <= 8 * 1024 * 1024 else { return nil }
                    flavors.append(.init(type: type.rawValue, data: data))
                }
                guard pasteboard.changeCount == expectedCount else { return nil }
            }
            if !flavors.isEmpty { saved.append(flavors) }
        }
        guard pasteboard.changeCount == expectedCount,
              let output = try? JSONEncoder().encode(Snapshot(changeCount: expectedCount, items: saved)),
              output.count <= 12 * 1024 * 1024 else { return nil }
        return output
    }
}
