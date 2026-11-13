import ArgumentParser
import Foundation
import MuesliCore

// Agent-facing dates use explicit UTC with milliseconds, not Foundation's
// numeric 2001 reference epoch. Existing persisted JSON keeps its encoding.
let historyDateEncoding: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var container = encoder.singleValueContainer()
    try container.encode(formatter.string(from: date))
}

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "history", abstract: "Retrieve bounded evidence for muesli history tasks. Run spec for examples.", subcommands: [HistorySample.self, HistoryRead.self])
}

struct HistorySample: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sample", abstract: "Sample a fixed interval across screen OCR and explicitly selected sources. Partial coverage; no model call.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Inclusive ISO-8601 timestamp with timezone.") var from: String
    @Option(name: .long, help: "Exclusive ISO-8601 timestamp with timezone (at most 31 days).") var until: String
    @Option(name: .long, help: "Comma-separated meetings,dictations,commands,quill,cotypist,chat,vidshots. Omit for screen history only.") var sources = ""
    @Option(name: .long, help: "Optional topic; at most 300 UTF-8 bytes. Applied before sampling.") var query = ""
    func run() throws {
        do { try execute() }
        catch let error as CLIError { throw error }
        catch { throw CLIError.databaseError(error.localizedDescription) }
    }
    private func execute() throws {
        let context = CLIContext(options: global)
        let start = try Self.date(from), end = try Self.date(until)
        guard start < end, end.timeIntervalSince(start) <= 31 * 86400, query.utf8.count <= 300 else {
            throw CLIError.invalidInput("Choose an interval of at most 31 days and a query of at most 300 bytes.")
        }
        let kinds = try Set(sources.split(separator: ",", omittingEmptySubsequences: false).filter { !$0.isEmpty }.map { name in
            guard let kind = MuesliHistoryKind(rawValue: String(name)) else { throw CLIError.invalidInput("Unknown history source: \(name)") }
            return kind
        })
        let root = context.supportDirectory.appendingPathComponent("visual-memory")
        // A never-created catalog is empty history. An existing unreadable catalog
        // remains an error; don't turn a permission/corruption failure into absence.
        let screen = FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path) ? root : nil
        let packet = try MuesliHistoryAccess(databaseURL: context.databaseURL, screenRoot: screen)
            .sample(interval: .init(start: start, end: end), kinds: kinds, query: query)
        emitSuccess(command: "muesli-cli history sample", data: packet, dbPath: context.databaseURL, dateEncodingStrategy: historyDateEncoding)
    }
    static func date(_ value: String) throws -> Date {
        guard value.range(of: #"T.*(?:Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else {
            throw CLIError.invalidInput("Timestamp must include a timezone.")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw CLIError.invalidInput("Invalid ISO-8601 timestamp.") }
        return date
    }
}

struct HistoryRead: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "read", abstract: "Read a current, revisioned text record. For meetings/screens use meetings get or time-turner get.")
    @OptionGroup var global: GlobalOptions
    @Argument var kind: String
    @Argument var id: String
    func run() throws {
        do { try execute() }
        catch let error as CLIError { throw error }
        catch { throw CLIError.databaseError(error.localizedDescription) }
    }
    private func execute() throws {
        guard let kind = MuesliHistoryKind(rawValue: kind), kind != .meetings else {
            throw CLIError.invalidInput("Choose dictations, commands, quill, cotypist, chat or vidshots.")
        }
        let context = CLIContext(options: global)
        guard let source = try MuesliHistoryReader(databaseURL: context.databaseURL).read(kind: kind, id: id) else {
            throw CLIError.notFound("Source is missing, deleted, or no longer valid.")
        }
        emitSuccess(command: "muesli-cli history read", data: source, dbPath: context.databaseURL, dateEncodingStrategy: historyDateEncoding)
    }
}

struct SkillsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "skills", abstract: "Discover shared history instructions and built-in task templates.", subcommands: [SkillsList.self, SkillsGet.self])
}
private struct SkillDescription: Encodable {
    let id: String
    let version: Int
    let title: String
    let summary: String
    let requiresQuery: Bool
    init(_ task: MuesliHistoryTask) {
        id = task.id; version = task.version; title = task.title; summary = task.summary; requiresQuery = task.requiresQuery
    }
}
private func skillCatalog(options: GlobalOptions) throws -> [MuesliHistoryTask] {
    struct Preferences: Decodable { let custom_meeting_templates: [CustomMeetingTemplate]? }
    let url = CLIContext(options: options).supportDirectory.appendingPathComponent("config.json")
    do {
        let config = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        return MuesliHistoryTask.catalog(custom: config.custom_meeting_templates ?? [])
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return MuesliHistoryTask.catalog(custom: [])
    } catch {
        throw CLIError.databaseError("Could not read skill preferences: " + error.localizedDescription)
    }
}
struct SkillsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List skills and meeting templates. Use get to read their instructions.")
    @OptionGroup var options: GlobalOptions
    func run() throws {
        emitSuccess(command: "muesli-cli skills list", data: try skillCatalog(options: options).map(SkillDescription.init), dbPath: nil)
    }
}
struct SkillsGet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read muesli-history or a task ID. --markdown exports an installable SKILL.md; never installs or executes it.")
    @OptionGroup var options: GlobalOptions
    @Argument var id: String
    @Flag(name: .long) var markdown = false
    func run() throws {
        let task = try skillCatalog(options: options).first { $0.id == id }
        guard task != nil || id == MuesliHistorySkill.id else { throw CLIError.notFound("Unknown skill: \(id)") }
        let text = try task.map { skill in
            if let prompt = skill.templatePrompt {
                let title = String(decoding: try JSONEncoder().encode(skill.title), as: UTF8.self)
                return "---\nname: \(skill.id)\ndescription: \(title)\n---\n\n" + prompt
            }
            return try skill.loadInstructions() + "\n" + MuesliHistorySkill.guide
        } ?? MuesliHistorySkill.markdown
        if markdown { print(text) }
        else { emitSuccess(command: "muesli-cli skills get", data: ["id": id, "instructions": text], dbPath: nil) }
    }
}
