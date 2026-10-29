import ArgumentParser
import Foundation
import MuesliCore
import MuesliNativeApp

struct CapturesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "captures", abstract: "Inspect local Scrawl captures.",
        subcommands: [CapturesListCommand.self, CapturesGetCommand.self, CapturesFramesCommand.self, CapturesZoomCommand.self])

    static func inputError(_ error: Error) -> CLIError {
        if let error = error as? CLIError { return error }
        if let error = error as? DecodingError {
            let context: DecodingError.Context
            switch error {
            case .dataCorrupted(let c), .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c): context = c
            @unknown default: return .invalidInput("Invalid Scrawl manifest: \(error)")
            }
            let detail = context.debugDescription.replacingOccurrences(of: "feedback capture", with: "Scrawl")
            return .invalidInput("Invalid Scrawl manifest: \(detail)")
        }
        if error is CancellationError { return .invalidInput("Scrawl zoom was cancelled.") }
        return .invalidInput("Scrawl: \(MuesliCLI.message(for: error))")
    }
    static func input<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw inputError(error) }
    }
    /// Error exits must keep the same command and resolved paths even for parser errors.
    static func failureContext(arguments: [String]) -> (command: String, context: CLIContext)? {
        guard arguments.first == "captures", let verb = arguments.dropFirst().first,
              ["list", "get", "frames", "zoom"].contains(verb) else { return nil }
        func option(_ name: String) -> String? {
            for (i, arg) in arguments.enumerated() {
                if arg == name, i + 1 < arguments.count { return arguments[i + 1] }
                if arg.hasPrefix(name + "=") { return String(arg.dropFirst(name.count + 1)) }
            }
            return nil
        }
        return ("muesli-cli captures \(verb)", CLIContext(dbPath: option("--db-path"), supportDir: option("--support-dir")))
    }
}

struct CaptureListRow: Encodable {
    let id: String
    let createdAtMs: Int64
    let durationMs: Int64
    let state: FeedbackCaptureState
    let title: String
    let bundlePath: String
    init(_ record: FeedbackCaptureRecord, store: FeedbackCaptureStore) throws {
        id = record.id; createdAtMs = Int64((record.createdAt * 1000).rounded()); durationMs = record.durationMs
        state = record.state; title = record.title; bundlePath = try store.bundleURL(id: record.id).path
    }
}
struct CapturePaths: Encodable {
    let manifest: String?
    let summary: String?
    let frames: [String]
    let contactSheet: String?
    let video: String?
    let audio: String?
}
struct CaptureDetailPayload: Encodable {
    let id: String
    let createdAtMs: Int64
    let durationMs: Int64
    let state: FeedbackCaptureState
    let title: String
    let bundlePath: String
    let summary: String
    let paths: CapturePaths
    let failures: [FeedbackCaptureFailure]
    let manifest: FeedbackCaptureManifest?
}
struct CaptureFramesPayload: Encodable {
    let id: String
    let contactSheet: String?
    let frames: [FeedbackCaptureKeyframe]
}
struct CaptureZoomPayload: Encodable {
    struct Frame: Encodable { let index: Int; let t: Int64; let file: String }
    let id: String
    let t0: Int64, t1: Int64
    let contactSheet: String
    let frames: [Frame]
    let words: [FeedbackCaptureTranscript.Span]
    let said: String
    let estimated: Bool
    let missing: FeedbackCaptureTranscript.Missing?
    let failures: [FeedbackCaptureFailure]
}

struct CapturesReader {
    let store: FeedbackCaptureStore
    let context: CLIContext
    let warnings: [String]
    private let renderZoom: (FeedbackCaptureManifest, URL, String?, Int?) async throws -> FeedbackCaptureRenderer.ZoomOutput
    init(context: CLIContext,
         renderZoom: @escaping (FeedbackCaptureManifest, URL, String?, Int?) async throws -> FeedbackCaptureRenderer.ZoomOutput = { manifest, url, at, mark in
             try await FeedbackCaptureRenderer.zoom(manifest, url: url, at: at, mark: mark)
         }) throws {
        self.context = context
        self.renderZoom = renderZoom
        try ensureDatabaseAvailable(context, command: "muesli-cli captures")
        (store, warnings) = try withMigration(context) {
            try Self.database { try FeedbackCaptureStore(databaseURL: context.databaseURL, support: context.supportDirectory) }
        }
    }
    private static func database<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw CLIError.databaseError(error.localizedDescription) }
    }
    private func database<T>(_ body: () throws -> T) throws -> T {
        try withMigration(context, migrate: { _ in warnings }) { try Self.database(body) }.0
    }
    func list(limit: Int) throws -> [CaptureListRow] {
        let rows = try database { try store.list() }
        return try CapturesCommand.input { try rows.prefix(limit).map { try CaptureListRow($0, store: store) } }
    }
    struct Snapshot {
        let record: FeedbackCaptureRecord
        let manifest: FeedbackCaptureManifest
        let available: FeedbackCaptureManifest
        let paths: CapturePaths
        let bundle: URL
        var warnings: [String]
    }
    func load(_ selector: String) throws -> Snapshot {
        let id: String
        if selector == "latest" {
            guard let row = try database({ try store.list().first }) else { throw CLIError.notFound("No Scrawl captures are saved.") }
            id = row.id
        } else { id = selector }
        return try CapturesCommand.input {
            let journal = try store.mediaURL(id: id, path: "unfinished.json")
            let hasJournal = FileManager.default.fileExists(atPath: journal.path)
            // Journal reads can fail manifest validation; row reads can fail SQLite.
            let record = try hasJournal ? store.get(id: id) : database { try store.get(id: id) }
            guard let record else { throw CLIError.notFound("No Scrawl capture exists with id \(id).") }
            let m = try store.manifest(id: id), bundle = try store.bundleURL(id: id)
            var warnings = self.warnings, available = m
            func artifact(_ path: String?) throws -> String? {
                guard let path else { return nil }
                let url = try store.mediaURL(id: id, path: path)
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      FileManager.default.isReadableFile(atPath: url.path) else {
                    warnings.append("Scrawl artifact unavailable: \(path)"); return nil
                }
                return url.path
            }
            // Validate every declaration, including mark links that are not displayed here.
            for path in m.marks.compactMap(\.frame) { _ = try store.mediaURL(id: id, path: path) }
            for (name, path) in [("audio", m.audio), ("video", m.video), ("contact sheet", m.contactSheet)] where path == nil {
                warnings.append("Scrawl \(name) unavailable.")
            }
            if m.keyframes.isEmpty { warnings.append("Scrawl saved frames unavailable.") }
            let audio = try artifact(m.audio), video = try artifact(m.video), sheet = try artifact(m.contactSheet)
            var frames: [FeedbackCaptureKeyframe] = [], framePaths: [String] = []
            for frame in m.keyframes {
                if let path = try artifact(frame.file) { frames.append(frame); framePaths.append(path) }
            }
            available.audio = audio == nil ? nil : m.audio; available.video = video == nil ? nil : m.video
            available.contactSheet = sheet == nil ? nil : m.contactSheet; available.keyframes = frames
            FeedbackCaptureContext.linkMarks(&available)
            let manifestPath = try artifact(FileManager.default.fileExists(atPath: journal.path) ? "unfinished.json" : "capture.json")
            let paths = CapturePaths(manifest: manifestPath, summary: try artifact("summary.md"), frames: framePaths,
                                     contactSheet: sheet, video: video, audio: audio)
            if m.state == .recording || m.state == .processing { warnings.append("Scrawl is \(m.state.rawValue); artifacts may be incomplete.") }
            return Snapshot(record: record, manifest: m, available: available, paths: paths, bundle: bundle, warnings: warnings)
        }
    }
    func get(_ selector: String, includeManifest: Bool) throws -> (CaptureDetailPayload, [String]) {
        var snapshot = try load(selector)
        let m = snapshot.manifest
        let summary: String
        if let path = snapshot.paths.summary { summary = try CapturesCommand.input { try String(contentsOfFile: path, encoding: .utf8) } }
        else {
            snapshot.warnings.append("Scrawl saved summary unavailable; regenerated from available artifacts.")
            let generated = FeedbackCaptureContext.summary(snapshot.available, bundle: snapshot.bundle)
            summary = generated.replacingOccurrences(of: "Manifest: \(snapshot.bundle.appendingPathComponent("capture.json").path)",
                with: snapshot.paths.manifest.map { "Manifest: \($0)" } ?? "Manifest unavailable")
        }
        return (CaptureDetailPayload(id: m.id, createdAtMs: m.createdAtMs, durationMs: m.durationMs, state: m.state,
            title: m.transcript?.firstClause ?? snapshot.record.title, bundlePath: snapshot.bundle.path, summary: summary,
            paths: snapshot.paths, failures: m.failures, manifest: includeManifest ? m : nil), snapshot.warnings)
    }
    func frames(_ selector: String) throws -> (CaptureFramesPayload, [String]) {
        let snapshot = try load(selector)
        var frames = snapshot.available.keyframes
        for i in frames.indices { frames[i].file = snapshot.paths.frames[i] }
        return (CaptureFramesPayload(id: snapshot.manifest.id, contactSheet: snapshot.paths.contactSheet, frames: frames), snapshot.warnings)
    }
    func zoom(_ selector: String, at: String?, mark: Int?) async throws -> (CaptureZoomPayload, [String]) {
        let snapshot = try load(selector), m = snapshot.manifest
        guard let video = snapshot.paths.video else { throw CLIError.invalidInput("Scrawl zoom requires available video.") }
        let output: FeedbackCaptureRenderer.ZoomOutput
        do { output = try await renderZoom(m, URL(fileURLWithPath: video), at, mark) }
        catch { throw CapturesCommand.inputError(error) }
        try Task.checkCancellation()
        let result = try CapturesCommand.input {
            try store.withExistingBundleMutation(id: m.id) { bundle in
                let root = try store.mediaURL(id: m.id, path: "zoom")
                guard root == bundle.appendingPathComponent("zoom") else { throw CLIError.invalidInput("Invalid Scrawl zoom directory.") }
                var isDirectory = ObjCBool(false)
                if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else { throw CLIError.invalidInput("Invalid Scrawl zoom directory.") }
                } else {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                }
                let relative = "zoom/\(UUID().uuidString)"
                let directory = try store.mediaURL(id: m.id, path: relative)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                var complete = false
                defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
                var frames: [CaptureZoomPayload.Frame] = [], failures = m.failures + output.failures
                for frame in output.frames {
                    try Task.checkCancellation()
                    do {
                        let url = try store.mediaURL(id: m.id, path: "\(relative)/frame-\(frame.index).png")
                        try frame.png.write(to: url, options: .atomic)
                        frames.append(.init(index: frame.index, t: frame.t, file: url.path))
                    } catch { failures.append(.init(stage: "zoom", message: "Frame #\(frame.index): \(error.localizedDescription)")) }
                }
                try Task.checkCancellation()
                let sheet = try store.mediaURL(id: m.id, path: "\(relative)/contact-sheet.png")
                try output.contactSheet.write(to: sheet, options: .atomic)
                try Task.checkCancellation()
                complete = true
                let c = output.context
                return (CaptureZoomPayload(id: m.id, t0: c.t0, t1: c.t1, contactSheet: sheet.path, frames: frames,
                    words: c.words, said: c.said, estimated: c.estimated, missing: c.missing, failures: failures), snapshot.warnings)
            }
        }
        guard let result else { throw CLIError.notFound("No Scrawl capture exists with id \(m.id).") }
        return result
    }
}

struct CapturesListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List recent Scrawl captures.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Maximum number of Scrawl captures to return.") var limit = 10
    func validate() throws { if limit <= 0 { throw CLIError.invalidInput("Scrawl --limit must be greater than zero.") } }
    func run() throws {
        let context = CLIContext(options: global)
        guard context.store.databaseExists else {
            emitSuccess(command: "muesli-cli captures list", data: [CaptureListRow](), dbPath: context.databaseURL,
                        warnings: ["No Muesli database exists at the resolved path."]); return
        }
        let reader = try CapturesReader(context: context)
        emitSuccess(command: "muesli-cli captures list", data: try reader.list(limit: limit), dbPath: context.databaseURL, warnings: reader.warnings)
    }
}
struct CapturesGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read a Scrawl summary and artifact paths.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Scrawl capture ID or latest.") var id: String
    @Flag(name: .long, help: "Include the validated Scrawl manifest.") var manifest = false
    func run() throws {
        let context = CLIContext(options: global), reader = try CapturesReader(context: context)
        let (payload, warnings) = try reader.get(id, includeManifest: manifest)
        emitSuccess(command: "muesli-cli captures get", data: payload, dbPath: context.databaseURL, warnings: warnings)
    }
}
struct CapturesFramesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "frames", abstract: "Read available Scrawl screenshots.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Scrawl capture ID or latest.") var id: String
    func run() throws {
        let context = CLIContext(options: global), reader = try CapturesReader(context: context)
        let (payload, warnings) = try reader.frames(id)
        emitSuccess(command: "muesli-cli captures frames", data: payload, dbPath: context.databaseURL, warnings: warnings)
    }
}
struct CapturesZoomCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "zoom", abstract: "Render a bounded Scrawl span with narration.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Scrawl capture ID or latest.") var id: String
    @Option(name: .long, help: "Scrawl timestamp M:SS (±2 seconds).") var at: String?
    @Option(name: .long, help: "Stable Scrawl mark mN (±1 second).") var mark: Int?
    func validate() throws {
        try CapturesCommand.input { try FeedbackCaptureContext.validateZoomSelector(at: at, mark: mark) }
    }
    func run() async throws {
        let context = CLIContext(options: global), reader = try CapturesReader(context: context)
        let (payload, warnings) = try await reader.zoom(id, at: at, mark: mark)
        emitSuccess(command: "muesli-cli captures zoom", data: payload, dbPath: context.databaseURL, warnings: warnings)
    }
}
