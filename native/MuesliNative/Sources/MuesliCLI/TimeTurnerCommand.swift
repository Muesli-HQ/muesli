import ArgumentParser
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import MuesliCore

struct TimeTurnerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "time-turner", abstract: "Search local screen history and read screenshots with OCR.", subcommands: [TimeTurnerSearch.self, TimeTurnerGet.self])
}

private func runTimeTurner(command: String, options: GlobalOptions, operation: () throws -> Void) throws {
    do { try operation() }
    catch {
        let failure = (error as? CLIError) ?? .databaseError(error.localizedDescription)
        let database = CLIContext(options: options).supportDirectory.appendingPathComponent("visual-memory/catalog.sqlite")
        emitFailure(command: command, error: failure.errorBody, dbPath: database)
        throw ExitCode(failure.exitCode)
    }
}

private func openTimeTurner(_ options: GlobalOptions) throws -> VisualMemoryStore {
    let root = CLIContext(options: options).supportDirectory.appendingPathComponent("visual-memory")
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path) else {
        throw CLIError.databaseUnavailable("No Time Turner catalog at \(root.path).", fix: "Use --support-dir to select the correct app lane.")
    }
    do { return try VisualMemoryStore(root: root, readOnly: true) }
    catch { throw CLIError.databaseError(error.localizedDescription) }
}

private func captureDate(_ value: String?) throws -> Date? {
    guard let value else { return nil }
    // Require a timezone; date-only and machine-local interpretations are ambiguous for agents.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        throw CLIError.invalidInput("Expected an ISO-8601 timestamp with timezone: \(value)", fix: "Example: 2026-10-23T00:00:00+05:30")
    }
    return date
}

private struct CapturePayload: Encodable {
    let id: String
    let capturedAt: String
    let capturedAtUnix: Double
    let source: String
    let bundleID: String
    let ocrText: String
    let mediaPath: String
    let archiveFrameIndex: Int?
    let mediaExists: Bool
    let screenshotPath: String?
    init(_ item: VisualMemoryItem, store: VisualMemoryStore, screenshot: String? = nil) throws {
        id = item.id
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        capturedAt = formatter.string(from: item.capturedAt)
        capturedAtUnix = item.capturedAt.timeIntervalSince1970
        source = item.source; bundleID = item.bundleID; ocrText = item.text
        mediaPath = try store.url(for: item.path).path
        archiveFrameIndex = item.frameIndex
        mediaExists = FileManager.default.fileExists(atPath: mediaPath)
        screenshotPath = screenshot
    }
}

struct TimeTurnerSearch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search OCR/source text; return JSON captures newest first. Reads only.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Literal word or phrase; omit to browse captures.") var query: String = ""
    @Option(name: .long, help: "Inclusive ISO-8601 capture time, with timezone.") var from: String?
    @Option(name: .long, help: "Exclusive ISO-8601 capture time, with timezone.") var until: String?
    @Option(name: .long, help: "Exact bundle ID or app name, case-insensitive.") var app: String?
    @Option(name: .long, help: "Maximum results, 1–1000.") var limit = 50
    func run() throws {
        try runTimeTurner(command: "muesli-cli time-turner search", options: global) { try execute() }
    }
    private func execute() throws {
        guard (1...1000).contains(limit) else { throw CLIError.invalidInput("--limit must be between 1 and 1000.") }
        let start = try captureDate(from) ?? .distantPast
        let end = try captureDate(until) ?? .distantFuture
        guard start < end else { throw CLIError.invalidInput("--from must be earlier than --until.") }
        let store = try openTimeTurner(global)
        do {
            let rows = try store.searchMoments(text: query, from: start, until: end, app: app, limit: limit)
            let captures = try rows.map { try CapturePayload($0, store: store) }
            emitSuccess(command: "muesli-cli time-turner search", data: captures, dbPath: store.root.appendingPathComponent("catalog.sqlite"), warnings: rows.count == limit ? ["Result limit reached; narrow the time range to retrieve additional captures."] : [])
        } catch let error as CLIError { throw error }
        catch { throw CLIError.databaseError(error.localizedDescription) }
    }
}

struct TimeTurnerGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read a capture's OCR and metadata; optionally export its exact screenshot as PNG for a vision-capable agent.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Capture ID from time-turner search.") var id: String
    @Option(name: .long, help: "Write a PNG screenshot to a new file; existing files are never overwritten.") var output: String?
    func run() throws {
        try runTimeTurner(command: "muesli-cli time-turner get", options: global) { try execute() }
    }
    private func execute() throws {
        let store = try openTimeTurner(global)
        do {
            guard let item = try store.moment(id: id) else { throw CLIError.notFound("Capture not found: \(id)") }
            var screenshot: String?
            if let output {
                let destination = URL(fileURLWithPath: output).standardizedFileURL
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw CLIError.invalidInput("Output already exists: \(destination.path)") }
                let source = try store.url(for: item.path)
                guard FileManager.default.fileExists(atPath: source.path) else { throw CLIError.notFound("Capture media is missing or expired.") }
                let image: CGImage
                if let frame = item.frameIndex {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    image = try generator.copyCGImage(at: CMTime(value: Int64(frame), timescale: 1), actualTime: nil)
                } else {
                    guard let decoded = CGImageSourceCreateWithURL(source as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(decoded, 0, nil) else { throw CLIError.notFound("Capture image cannot be decoded.") }
                    image = cg
                }
                guard image.width >= 100, image.height >= 100 else { throw CLIError.notFound("Capture image is incomplete.") }
                let data = NSMutableData()
                guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CLIError.databaseError("Could not create PNG encoder.") }
                CGImageDestinationAddImage(encoder, image, nil)
                guard CGImageDestinationFinalize(encoder) else { throw CLIError.databaseError("PNG encoding failed.") }
                try (data as Data).write(to: destination, options: .withoutOverwriting)
                screenshot = destination.path
            }
            emitSuccess(command: "muesli-cli time-turner get", data: try CapturePayload(item, store: store, screenshot: screenshot), dbPath: store.root.appendingPathComponent("catalog.sqlite"))
        } catch let error as CLIError { throw error }
        catch { throw CLIError.databaseError(error.localizedDescription) }
    }
}
