import Foundation
import ZIPFoundation

public struct GranolaImportRecord: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let createdAt: Date
    public let summary: String
    public let notes: String
    public let transcript: String
    public let workspace: String
    public let ownerEmail: String

    /// Stable across files and devices; never reuse calendar_event_id for import identity.
    public var syncIdentity: String { "meeting-granola-\(id)" }
}

public struct GranolaImportReport: Sendable {
    public let imported: Int
    public let skipped: Int
}

public enum GranolaImportError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum GranolaImport {
    public static let maximumBytes = 50 * 1024 * 1024
    public static let maximumMeetings = 10_000
    private static let columns = ["document_id", "user_email", "document_title", "workspace_name", "document_created", "summary", "notes", "transcript"]

    public static func read(files: [URL]) throws -> [GranolaImportRecord] {
        var records: [GranolaImportRecord] = []
        var inputBytes = 0
        var contentBytes = 0
        func appendCSV(_ data: Data) throws {
            guard data.count <= maximumBytes - contentBytes else {
                throw GranolaImportError.invalid("The export exceeds 50 MB of uncompressed CSV data.")
            }
            contentBytes += data.count
            records += try parse(data)
            guard records.count <= maximumMeetings else { throw GranolaImportError.invalid("Import up to 10,000 meetings at a time.") }
        }
        for url in files {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes - inputBytes else {
                throw GranolaImportError.invalid("Choose ZIP or CSV files totaling no more than 50 MB.")
            }
            let data = try Data(contentsOf: url)
            inputBytes += data.count
            guard inputBytes <= maximumBytes else { throw GranolaImportError.invalid("The export exceeds 50 MB.") }
            switch url.pathExtension.lowercased() {
            case "csv": try appendCSV(data)
            case "zip":
                do {
                    let count = try zipEntryCount(data)
                    let archive = try Archive(data: data, accessMode: .read)
                    let entries = Array(archive.prefix(count + 1))
                    // ZIPFoundation's iterator stops at an unreadable/encrypted entry.
                    // Never silently import the readable prefix of a damaged archive.
                    guard entries.count == count else { throw GranolaImportError.invalid("The ZIP is damaged or encrypted. Download a new export from Granola.") }
                    var csvCount = 0
                    for entry in entries {
                        let components = entry.path.split(separator: "/")
                        guard !components.contains("__MACOSX"), !components.contains(where: { $0.hasPrefix(".") && $0 != ".." && $0 != "." }),
                              (entry.path as NSString).pathExtension.lowercased() == "csv" else { continue }
                        guard entry.type == .file, !entry.path.hasPrefix("/"), !components.contains(".."), !entry.path.contains("\\") else {
                            throw GranolaImportError.invalid("The ZIP contains an unsupported CSV entry.")
                        }
                        guard entry.uncompressedSize <= UInt64(maximumBytes - contentBytes) else {
                            throw GranolaImportError.invalid("The export exceeds 50 MB of uncompressed CSV data.")
                        }
                        var csv = Data()
                        let checksum = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                            guard chunk.count <= maximumBytes - contentBytes - csv.count else {
                                throw GranolaImportError.invalid("The export exceeds 50 MB of uncompressed CSV data.")
                            }
                            csv.append(chunk)
                        }
                        guard checksum == entry.checksum, UInt64(csv.count) == entry.uncompressedSize else {
                            throw GranolaImportError.invalid("A CSV in the ZIP is damaged. Download a new export from Granola.")
                        }
                        try appendCSV(csv)
                        csvCount += 1
                    }
                    guard csvCount > 0 else { throw GranolaImportError.invalid("This ZIP contains no CSV files.") }
                } catch let error as GranolaImportError { throw error }
                catch { throw GranolaImportError.invalid("Couldn’t read this ZIP. Download a new Granola export or choose its CSV files.") }
            default: throw GranolaImportError.invalid("Choose a Granola ZIP or CSV export.")
            }
        }
        guard !records.isEmpty else { throw GranolaImportError.invalid("This export contains no meetings.") }
        return records.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt > rhs.createdAt
        }
    }

    /// Preflight the ordinary ZIP directory before handing entries to ZIPFoundation.
    /// Large/multi-disk ZIP variants are unnecessary within this import's 50 MB limit.
    private static func zipEntryCount(_ data: Data) throws -> Int {
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        guard data.count >= 22 else { throw GranolaImportError.invalid("This ZIP is incomplete.") }
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            guard data[offset..<offset + 4].elementsEqual([0x50, 0x4b, 0x05, 0x06]),
                  offset + 22 + u16(offset + 20) == data.count else { continue }
            let count = u16(offset + 10)
            let hasZIP64Locator = offset >= 20 && data[(offset - 20)..<(offset - 16)].elementsEqual([0x50, 0x4b, 0x06, 0x07])
            guard u16(offset + 4) == 0, u16(offset + 6) == 0,
                  u16(offset + 8) == count, count < 0xffff, !hasZIP64Locator else {
                throw GranolaImportError.invalid("This ZIP format isn’t supported. Choose the CSV files instead.")
            }
            guard count <= 1_000 else { throw GranolaImportError.invalid("Choose a ZIP with no more than 1,000 entries.") }
            return count
        }
        throw GranolaImportError.invalid("This ZIP is incomplete or damaged.")
    }

    public static func parse(_ data: Data) throws -> [GranolaImportRecord] {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw GranolaImportError.invalid("Choose a UTF-8 Granola CSV export no larger than 50 MB.")
        }
        let rows = try csvRows(text)
        guard let header = rows.first, Set(header).count == header.count,
              columns.allSatisfy(header.contains) else {
            throw GranolaImportError.invalid("This file does not have the expected Granola export columns. Export from Settings → Profile → Export historical data.")
        }
        let indexes = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        return try rows.dropFirst().enumerated().map { offset, row in
            guard row.count == header.count else { throw GranolaImportError.invalid("CSV row \(offset + 2) has the wrong number of columns.") }
            func value(_ key: String) -> String { row[indexes[key]!] }
            guard let id = UUID(uuidString: value("document_id")),
                  let date = fractional.date(from: value("document_created")) ?? standard.date(from: value("document_created")) else {
                throw GranolaImportError.invalid("CSV row \(offset + 2) has an invalid document ID or creation date. Nothing was imported.")
            }
            guard [value("summary"), value("notes"), value("transcript")].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw GranolaImportError.invalid("CSV row \(offset + 2) has no summary, notes, or transcript.")
            }
            return GranolaImportRecord(id: id.uuidString.lowercased(), title: value("document_title"), createdAt: date,
                                       summary: value("summary"), notes: value("notes"), transcript: value("transcript"),
                                       workspace: value("workspace_name"), ownerEmail: value("user_email"))
        }
    }

    /// RFC 4180 quoting, including multiline fields and CRLF. Never evaluate cell contents.
    private static func csvRows(_ input: String) throws -> [[String]] {
        var scalars = input.unicodeScalars[...]
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        var rows: [[String]] = [], row: [String] = [], field = ""
        enum State { case start, unquoted, quoted, closed }
        var state: State = .start
        var previousCR = false
        func finishField() throws {
            // Bound allocations even for a small malformed file full of commas.
            // Once the header is known, each row must have exactly its column count.
            guard row.count < (rows.first?.count ?? 128) else {
                throw GranolaImportError.invalid("The CSV has too many columns.")
            }
            row.append(field); field = ""; state = .start
        }
        func finishRow() throws {
            try finishField()
            if row != [""] { rows.append(row) }
            row = []
            if rows.count > maximumMeetings + 1 { throw GranolaImportError.invalid("Import up to 10,000 meetings at a time.") }
        }
        for scalar in scalars {
            guard scalar != "\0" else { throw GranolaImportError.invalid("The CSV contains an unsupported null character.") }
            if state == .quoted {
                if scalar == "\"" { state = .closed } else { field.unicodeScalars.append(scalar) }
                continue
            }
            if previousCR && scalar == "\n" { previousCR = false; continue }
            previousCR = false
            switch scalar {
            case "\"":
                if state == .start { state = .quoted }
                else if state == .closed { field.append("\""); state = .quoted }
                else { throw GranolaImportError.invalid("The CSV contains an unexpected quote.") }
            case ",": try finishField()
            case "\r", "\n": try finishRow(); previousCR = scalar == "\r"
            default:
                guard state != .closed else { throw GranolaImportError.invalid("The CSV contains text after a closing quote.") }
                field.unicodeScalars.append(scalar); state = .unquoted
            }
        }
        guard state != .quoted else { throw GranolaImportError.invalid("The CSV ends inside a quoted field.") }
        if state != .start || !row.isEmpty || !field.isEmpty { try finishRow() }
        return rows
    }
}
