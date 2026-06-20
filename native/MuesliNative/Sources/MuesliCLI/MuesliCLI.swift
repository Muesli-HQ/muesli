import ArgumentParser
import Foundation
import MuesliCore

struct CLIContext {
    let supportDirectory: URL
    let databaseURL: URL

    init(options: GlobalOptions) {
        self.init(dbPath: options.dbPath, supportDir: options.supportDir)
    }

    init(dbPath: String?, supportDir: String?) {
        if let dbPath, !dbPath.isEmpty {
            self.databaseURL = URL(fileURLWithPath: dbPath)
            self.supportDirectory = URL(fileURLWithPath: supportDir ?? self.databaseURL.deletingLastPathComponent().path)
            return
        }

        if let supportDir, !supportDir.isEmpty {
            self.supportDirectory = URL(fileURLWithPath: supportDir)
            self.databaseURL = self.supportDirectory.appendingPathComponent("muesli.db")
            return
        }

        if let envDB = ProcessInfo.processInfo.environment["MUESLI_DB_PATH"], !envDB.isEmpty {
            self.databaseURL = URL(fileURLWithPath: envDB)
            self.supportDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUESLI_SUPPORT_DIR"] ?? self.databaseURL.deletingLastPathComponent().path)
            return
        }

        if let envSupport = ProcessInfo.processInfo.environment["MUESLI_SUPPORT_DIR"], !envSupport.isEmpty {
            self.supportDirectory = URL(fileURLWithPath: envSupport)
            self.databaseURL = self.supportDirectory.appendingPathComponent("muesli.db")
            return
        }

        self.supportDirectory = MuesliPaths.defaultSupportDirectoryURL()
        self.databaseURL = self.supportDirectory.appendingPathComponent("muesli.db")
    }

    var store: DictationStore { DictationStore(databaseURL: databaseURL) }
}

struct ErrorBody: Encodable {
    let code: String
    let message: String
    let fix: String?
}

struct MetaBody: Encodable {
    let schemaVersion: Int
    let generatedAt: String
    let dbPath: String
    let warnings: [String]
}

struct SuccessEnvelope<T: Encodable>: Encodable {
    let ok = true
    let command: String
    let data: T
    let meta: MetaBody
}

struct FailureEnvelope: Encodable {
    let ok = false
    let command: String
    let error: ErrorBody
    let meta: MetaBody
}

enum CLIError: Error {
    case invalidInput(String, fix: String? = nil)
    case notFound(String, fix: String? = nil)
    case databaseUnavailable(String, fix: String? = nil)
    case databaseError(String, fix: String? = nil)

    var errorBody: ErrorBody {
        switch self {
        case .invalidInput(let message, let fix):
            return ErrorBody(code: "invalid_input", message: message, fix: fix)
        case .notFound(let message, let fix):
            return ErrorBody(code: "not_found", message: message, fix: fix)
        case .databaseUnavailable(let message, let fix):
            return ErrorBody(code: "database_unavailable", message: message, fix: fix)
        case .databaseError(let message, let fix):
            return ErrorBody(code: "database_error", message: message, fix: fix)
        }
    }

    var exitCode: Int32 {
        switch self {
        case .invalidInput: return 4
        case .notFound: return 3
        case .databaseUnavailable: return 5
        case .databaseError: return 6
        }
    }
}

func timestampString(_ date: Date = Date()) -> String {
    ISO8601DateFormatter().string(from: date)
}

func appBundlePath() -> String? {
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let components = executableURL.pathComponents
    if let contentsIndex = components.lastIndex(of: "Contents"), contentsIndex >= 1 {
        let bundlePath = NSString.path(withComponents: Array(components.prefix(contentsIndex)))
        if bundlePath.hasSuffix(".app") {
            return bundlePath
        }
    }
    let defaultPath = "/Applications/Muesli.app"
    return FileManager.default.fileExists(atPath: defaultPath) ? defaultPath : nil
}

func emitSuccess<T: Encodable>(command: String, data: T, dbPath: URL, warnings: [String] = []) {
    let envelope = SuccessEnvelope(
        command: command,
        data: data,
        meta: MetaBody(schemaVersion: 1, generatedAt: timestampString(), dbPath: dbPath.path, warnings: warnings)
    )
    emitJSON(envelope)
}

func emitFailure(command: String, error: ErrorBody, dbPath: URL?) {
    let envelope = FailureEnvelope(
        command: command,
        error: error,
        meta: MetaBody(schemaVersion: 1, generatedAt: timestampString(), dbPath: dbPath?.path ?? "", warnings: [])
    )
    emitJSON(envelope)
}

func emitJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fputs("Failed to encode JSON output: \(error)\n", stderr)
    }
}

func ensureDatabaseAvailable(_ context: CLIContext, command: String) throws {
    guard context.store.databaseExists else {
        throw CLIError.databaseUnavailable(
            "No Muesli database exists at the resolved path.",
            fix: "Launch Muesli once or pass --db-path/--support-dir to point at the correct data directory."
        )
    }
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Override the absolute path to muesli.db.")
    var dbPath: String?

    @Option(name: .long, help: "Override the Muesli support directory. The CLI will look for muesli.db inside it.")
    var supportDir: String?
}

struct MeetingListRow: Encodable {
    let id: Int64
    let title: String
    let startTime: String
    let durationSeconds: Double
    let wordCount: Int
    let folderID: Int64?
    let status: String
    let manualNotes: String
    let notesState: String
    let selectedTemplateID: String
    let selectedTemplateName: String
    let selectedTemplateKind: String

    init(_ record: MeetingRecord) {
        id = record.id
        title = record.title
        startTime = record.startTime
        durationSeconds = record.durationSeconds
        wordCount = record.wordCount
        folderID = record.folderID
        status = record.status.rawValue
        manualNotes = record.manualNotes
        notesState = record.notesState.rawValue
        selectedTemplateID = record.appliedTemplateID
        selectedTemplateName = record.appliedTemplateName
        selectedTemplateKind = record.appliedTemplateKind.rawValue
    }
}

struct MeetingDetailPayload: Encodable {
    let id: Int64
    let title: String
    let startTime: String
    let durationSeconds: Double
    let rawTranscript: String
    let formattedNotes: String
    let wordCount: Int
    let folderID: Int64?
    let status: String
    let manualNotes: String
    let notesState: String
    let calendarEventID: String?
    let micAudioPath: String?
    let systemAudioPath: String?
    let savedRecordingPath: String?
    let selectedTemplateID: String
    let selectedTemplateName: String
    let selectedTemplateKind: String
    let selectedTemplatePrompt: String?

    init(_ record: MeetingRecord) {
        id = record.id
        title = record.title
        startTime = record.startTime
        durationSeconds = record.durationSeconds
        rawTranscript = record.rawTranscript
        formattedNotes = record.formattedNotes
        wordCount = record.wordCount
        folderID = record.folderID
        status = record.status.rawValue
        manualNotes = record.manualNotes
        notesState = record.notesState.rawValue
        calendarEventID = record.calendarEventID
        micAudioPath = record.micAudioPath
        systemAudioPath = record.systemAudioPath
        savedRecordingPath = record.savedRecordingPath
        selectedTemplateID = record.appliedTemplateID
        selectedTemplateName = record.appliedTemplateName
        selectedTemplateKind = record.appliedTemplateKind.rawValue
        selectedTemplatePrompt = record.selectedTemplatePrompt
    }
}

struct DictationListRow: Encodable {
    let id: Int64
    let timestamp: String
    let durationSeconds: Double
    let wordCount: Int
    let appContext: String

    init(_ record: DictationRecord) {
        id = record.id
        timestamp = record.timestamp
        durationSeconds = record.durationSeconds
        wordCount = record.wordCount
        appContext = record.appContext
    }
}

struct DictationDetailPayload: Encodable {
    let id: Int64
    let timestamp: String
    let durationSeconds: Double
    let wordCount: Int
    let appContext: String
    let rawText: String

    init(_ record: DictationRecord) {
        id = record.id
        timestamp = record.timestamp
        durationSeconds = record.durationSeconds
        wordCount = record.wordCount
        appContext = record.appContext
        rawText = record.rawText
    }
}

struct CommandSpecPayload: Encodable {
    struct SpecCommand: Encodable {
        let name: String
        let usage: String
        let summary: String
        let examples: [String]
    }

    let schemaVersion = 1
    let commands: [SpecCommand]
}

@main
struct MuesliCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "muesli-cli",
        abstract: "Agent-friendly CLI for local Muesli meetings and dictations.",
        subcommands: [SpecCommand.self, InfoCommand.self, MeetingsCommand.self, DictationsCommand.self]
    )

    static func exit(withError error: Error? = nil) -> Never {
        guard let error else {
            Foundation.exit(0)
        }

        if let cliError = error as? CLIError {
            emitFailure(command: CommandLine.arguments.joined(separator: " "), error: cliError.errorBody, dbPath: nil)
            Foundation.exit(cliError.exitCode)
        }

        if let validation = error as? ValidationError {
            emitFailure(
                command: CommandLine.arguments.joined(separator: " "),
                error: ErrorBody(code: "invalid_input", message: validation.message, fix: "Run `muesli-cli spec` for valid usage."),
                dbPath: nil
            )
            Foundation.exit(4)
        }

        let code = Int32(Self.exitCode(for: error).rawValue)
        emitFailure(
            command: CommandLine.arguments.joined(separator: " "),
            error: ErrorBody(code: "usage_error", message: error.localizedDescription, fix: "Run `muesli-cli spec` for valid usage."),
            dbPath: nil
        )
        Foundation.exit(code)
    }

    func run() throws {
        let payload = Self.specPayload()
        emitSuccess(command: "muesli-cli", data: payload, dbPath: CLIContext(options: .init()).databaseURL)
    }

    static func specPayload() -> CommandSpecPayload {
        CommandSpecPayload(commands: [
            .init(name: "spec", usage: "muesli-cli spec", summary: "Dump the command tree and CLI schema metadata.", examples: ["muesli-cli spec"]),
            .init(name: "info", usage: "muesli-cli info [--db-path <path>] [--support-dir <dir>]", summary: "Show resolved support and database paths.", examples: ["muesli-cli info", "muesli-cli info --support-dir ~/Library/Application\\ Support/Muesli"]),
            .init(name: "meetings list", usage: "muesli-cli meetings list [--limit <n>] [--folder-id <id>]", summary: "List recent meetings.", examples: ["muesli-cli meetings list --limit 5", "muesli-cli meetings list --folder-id 2"]),
            .init(name: "meetings get", usage: "muesli-cli meetings get <id>", summary: "Return a full meeting record.", examples: ["muesli-cli meetings get 42"]),
            .init(name: "meetings update-notes", usage: "muesli-cli meetings update-notes <id> (--stdin | --file <path>)", summary: "Replace stored meeting notes only.", examples: ["muesli-cli meetings update-notes 42 --file notes.md", "cat notes.md | muesli-cli meetings update-notes 42 --stdin"]),
            .init(name: "dictations list", usage: "muesli-cli dictations list [--limit <n>]", summary: "List recent dictations.", examples: ["muesli-cli dictations list --limit 10"]),
            .init(name: "dictations get", usage: "muesli-cli dictations get <id>", summary: "Return a full dictation record.", examples: ["muesli-cli dictations get 7"]),
        ])
    }
}

struct SpecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "spec", abstract: "Dump CLI command metadata as JSON.")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        let context = CLIContext(options: global)
        emitSuccess(command: "muesli-cli spec", data: MuesliCLI.specPayload(), dbPath: context.databaseURL)
    }
}

struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "info", abstract: "Show resolved support and database paths.")
    @OptionGroup var global: GlobalOptions

    struct Payload: Encodable {
        let supportDirectory: String
        let databasePath: String
        let databaseExists: Bool
        let appBundlePath: String?
        let executablePath: String
        let schemaVersion = 1
    }

    func run() throws {
        let context = CLIContext(options: global)
        emitSuccess(
            command: "muesli-cli info",
            data: Payload(
                supportDirectory: context.supportDirectory.path,
                databasePath: context.databaseURL.path,
                databaseExists: context.store.databaseExists,
                appBundlePath: appBundlePath(),
                executablePath: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            ),
            dbPath: context.databaseURL
        )
    }
}

struct MeetingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "meetings", abstract: "Inspect and update Muesli meetings.", subcommands: [MeetingsListCommand.self, MeetingsGetCommand.self, MeetingsUpdateNotesCommand.self])
}

struct MeetingsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List recent meetings.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Maximum number of meetings to return.") var limit: Int = 10
    @Option(name: .long, help: "Restrict results to a specific folder ID.") var folderID: Int64?

    func run() throws {
        let context = CLIContext(options: global)
        guard limit > 0 else {
            throw CLIError.invalidInput("--limit must be greater than zero.", fix: "Pass a positive integer such as --limit 10.")
        }
        if !context.store.databaseExists {
            emitSuccess(command: "muesli-cli meetings list", data: [MeetingListRow](), dbPath: context.databaseURL, warnings: ["No Muesli database exists at the resolved path."])
            return
        }
        let rows = try context.store.recentMeetings(limit: limit, folderID: folderID).map(MeetingListRow.init)
        emitSuccess(command: "muesli-cli meetings list", data: rows, dbPath: context.databaseURL)
    }
}

struct MeetingsGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Return a full meeting record.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Meeting ID") var id: Int64

    func run() throws {
        let context = CLIContext(options: global)
        try ensureDatabaseAvailable(context, command: "muesli-cli meetings get")
        guard let meeting = try context.store.meeting(id: id) else {
            throw CLIError.notFound("No meeting exists with id \(id).", fix: "Run `muesli-cli meetings list` to find a valid ID.")
        }
        emitSuccess(command: "muesli-cli meetings get", data: MeetingDetailPayload(meeting), dbPath: context.databaseURL)
    }
}

struct MeetingsUpdateNotesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update-notes", abstract: "Replace stored meeting notes only.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Meeting ID") var id: Int64
    @Flag(name: .long, help: "Read the new notes body from stdin.") var stdin = false
    @Option(name: .long, help: "Read the new notes body from a file.") var file: String?

    mutating func validate() throws {
        if stdin == (file != nil) {
            throw ValidationError("Use exactly one of --stdin or --file.")
        }
    }

    func run() throws {
        let context = CLIContext(options: global)
        try ensureDatabaseAvailable(context, command: "muesli-cli meetings update-notes")
        guard try context.store.meeting(id: id) != nil else {
            throw CLIError.notFound("No meeting exists with id \(id).", fix: "Run `muesli-cli meetings list` to find a valid ID.")
        }

        let notes: String
        if stdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            notes = String(decoding: data, as: UTF8.self)
        } else if let file {
            notes = try String(contentsOfFile: file, encoding: .utf8)
        } else {
            throw CLIError.invalidInput("No notes source was provided.", fix: "Use --stdin or --file <path>.")
        }

        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError.invalidInput("Meeting notes cannot be empty.", fix: "Provide a non-empty markdown or plain text notes body.")
        }

        try context.store.updateMeetingNotes(id: id, formattedNotes: notes)
        MuesliNotifications.postDataDidChange()

        guard let updated = try context.store.meeting(id: id) else {
            throw CLIError.databaseError("The meeting was updated but could not be reloaded.")
        }
        emitSuccess(command: "muesli-cli meetings update-notes", data: MeetingDetailPayload(updated), dbPath: context.databaseURL)
    }
}

struct DictationsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dictations", abstract: "Inspect Muesli dictations.", subcommands: [DictationsListCommand.self, DictationsGetCommand.self])
}

struct DictationsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List recent dictations.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Maximum number of dictations to return.") var limit: Int = 10

    func run() throws {
        let context = CLIContext(options: global)
        guard limit > 0 else {
            throw CLIError.invalidInput("--limit must be greater than zero.", fix: "Pass a positive integer such as --limit 10.")
        }
        if !context.store.databaseExists {
            emitSuccess(command: "muesli-cli dictations list", data: [DictationListRow](), dbPath: context.databaseURL, warnings: ["No Muesli database exists at the resolved path."])
            return
        }
        let rows = try context.store.recentDictations(limit: limit).map(DictationListRow.init)
        emitSuccess(command: "muesli-cli dictations list", data: rows, dbPath: context.databaseURL)
    }
}

struct DictationsGetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Return a full dictation record.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Dictation ID") var id: Int64

    func run() throws {
        let context = CLIContext(options: global)
        try ensureDatabaseAvailable(context, command: "muesli-cli dictations get")
        guard let dictation = try context.store.dictation(id: id) else {
            throw CLIError.notFound("No dictation exists with id \(id).", fix: "Run `muesli-cli dictations list` to find a valid ID.")
        }
        emitSuccess(command: "muesli-cli dictations get", data: DictationDetailPayload(dictation), dbPath: context.databaseURL)
    }
}
