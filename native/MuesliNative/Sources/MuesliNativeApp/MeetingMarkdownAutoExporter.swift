import Foundation
import MuesliCore
import Darwin
import os

/// Automatically writes completed meeting exports to a
/// user-configured folder. Mirrors the meeting-hook dispatch pattern by
/// dispatching export work away from the meeting persistence path.
protocol MeetingMarkdownAutoExporting {
    /// Participants arrive as a provider rather than a materialized list. This type
    /// owns no database handle, so the caller supplies the read — but running it here
    /// rather than at the call site keeps a SQLite query off the main-actor meeting
    /// persistence path, and lets `resolveParticipants` retry lock contention before
    /// committing to a one-shot artifact that would otherwise silently lose its
    /// People line.
    func exportIfConfigured(
        meeting: MeetingRecord,
        loadParticipants: @escaping @Sendable () throws -> [MeetingParticipant],
        config: AppConfig
    )
    func recordMeetingLookupFailure(meetingID: Int64, error: Error?)
}

final class MeetingMarkdownAutoExporter: MeetingMarkdownAutoExporting {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MarkdownAutoExport")

    private let supportDirectory: URL
    private let fileManager: FileManager
    private let logQueue = DispatchQueue(label: "com.muesli.native.markdown-auto-export-log")
    private let dateProvider: () -> Date

    init(
        supportDirectory: URL = AppIdentity.supportDirectoryURL,
        fileManager: FileManager = .default,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.supportDirectory = supportDirectory
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    var logURL: URL {
        supportDirectory.appendingPathComponent("meeting-markdown-export.log")
    }

    func exportIfConfigured(
        meeting: MeetingRecord,
        loadParticipants: @escaping @Sendable () throws -> [MeetingParticipant],
        config: AppConfig
    ) {
        guard config.autoExportMarkdownEnabled else { return }
        Task.detached(priority: .utility) { [self] in
            await performExport(meeting: meeting, loadParticipants: loadParticipants, config: config)
        }
    }

    func recordMeetingLookupFailure(meetingID: Int64, error: Error?) {
        if let error {
            writeLog("export failed: could not load persisted meeting id=\(meetingID) error=\(error.localizedDescription)")
        } else {
            writeLog("export failed: persisted meeting not found id=\(meetingID)")
        }
    }

    /// Records that participants could not be loaded for an export that still went
    /// ahead without them. Deliberately logs only the meeting id, the attempt count,
    /// and the error, never participant names.
    func recordParticipantLookupFailure(meetingID: Int64, error: Error, attempts: Int = 1) {
        writeLog(
            "export incomplete: could not load participants id=\(meetingID) attempts=\(attempts) "
                + "error=\(error.localizedDescription); exported without the People line"
        )
    }

    // MARK: - Participants

    /// Resolves the participant snapshot for an export, retrying lock contention.
    ///
    /// An automatic export is written exactly once and never revisited, so a single
    /// `SQLITE_BUSY` read would cost that file its People line permanently. Retrying
    /// is what actually repairs that case; the log below is only for the residue that
    /// no retry can fix. A deterministic fault gives up on the first attempt rather
    /// than stalling the export behind three pointless sleeps.
    private func resolveParticipants(
        meetingID: Int64,
        load: @Sendable () throws -> [MeetingParticipant]
    ) async -> [MeetingParticipant] {
        var attempt = 0
        while true {
            do {
                return try load()
            } catch {
                guard attempt < DictationStore.transientLockRetryDelays.count,
                      DictationStore.isTransientLockFailure(error) else {
                    recordParticipantLookupFailure(
                        meetingID: meetingID,
                        error: error,
                        attempts: attempt + 1
                    )
                    return []
                }
                try? await Task.sleep(for: DictationStore.transientLockRetryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// Builds the export payloads and writes them to disk. Returns the written URLs on
    /// success (exposed for testing); logs and returns nil on any failure.
    @discardableResult
    func performExport(
        meeting: MeetingRecord,
        loadParticipants: @Sendable () throws -> [MeetingParticipant] = { [] },
        config: AppConfig
    ) async -> [URL]? {
        let trimmedFolder = config.autoExportMarkdownFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFolder.isEmpty else {
            writeLog("skipped: auto-export enabled but no destination folder configured")
            return nil
        }
        guard NSString(string: trimmedFolder).isAbsolutePath else {
            writeLog("skipped: destination folder must be an absolute path path=\(trimmedFolder)")
            return nil
        }

        let folderURL = URL(fileURLWithPath: trimmedFolder, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            writeLog("export failed: could not create destination folder path=\(folderURL.path) error=\(error.localizedDescription)")
            return nil
        }

        // Deliberately after the destination checks above: an export that is going to
        // be skipped should not touch the database at all.
        let participants = await resolveParticipants(meetingID: meeting.id, load: loadParticipants)

        let content = config.resolvedAutoExportMarkdownContent
        let fileFormat = config.resolvedAutoExportFileFormat
        let markdown = MeetingExporter.buildMarkdown(
            meeting: meeting,
            content: content,
            participants: participants
        )
        var writtenURLs: [URL] = []

        if fileFormat.includesMarkdown {
            do {
                let destinationURL = try writeMarkdown(markdown, in: folderURL, meeting: meeting, content: content)
                writtenURLs.append(destinationURL)
            } catch {
                writeLog("export failed: id=\(meeting.id) format=markdown error=\(error.localizedDescription)")
            }
        }

        if fileFormat.includesPDF {
            do {
                let destinationURL = try await writePDF(markdown, in: folderURL, meeting: meeting, content: content)
                writtenURLs.append(destinationURL)
            } catch {
                writeLog("export failed: id=\(meeting.id) format=pdf error=\(error.localizedDescription)")
            }
        }

        guard !writtenURLs.isEmpty else {
            return nil
        }

        let paths = writtenURLs.map(\.path).joined(separator: ", ")
        writeLog("exported: id=\(meeting.id) paths=\(paths)")
        return writtenURLs
    }

    // MARK: - Filename

    private func writeMarkdown(
        _ markdown: String,
        in folder: URL,
        meeting: MeetingRecord,
        content: MeetingExportContent
    ) throws -> URL {
        let baseName = baseFilename(meeting: meeting, content: content, fileExtension: "md")
        let data = Data(markdown.utf8)
        let firstCandidate = folder.appendingPathComponent("\(baseName).md")
        if try write(data, toNewFileAt: firstCandidate) {
            return firstCandidate
        }

        for index in 2...Self.maxCollisionAttempts {
            let candidate = folder.appendingPathComponent("\(baseName)-\(index).md")
            if try write(data, toNewFileAt: candidate) {
                return candidate
            }
        }

        // Degenerate case (folder saturated with the same base name): fall back to
        // a UUID-suffixed name so we never overwrite and never loop unbounded.
        let fallback = folder.appendingPathComponent("\(baseName)-\(UUID().uuidString).md")
        guard try write(data, toNewFileAt: fallback) else {
            throw CocoaError(.fileWriteFileExists)
        }
        return fallback
    }

    private func writePDF(
        _ markdown: String,
        in folder: URL,
        meeting: MeetingRecord,
        content: MeetingExportContent
    ) async throws -> URL {
        return try await writeReservedFile(
            in: folder,
            meeting: meeting,
            content: content,
            fileExtension: "pdf"
        ) { url in
            try await MainActor.run {
                let attributed = MeetingExporter.buildAttributedString(from: markdown)
                try MeetingExporter.writePDF(attributed: attributed, to: url)
            }
        }
    }

    private func writeReservedFile(
        in folder: URL,
        meeting: MeetingRecord,
        content: MeetingExportContent,
        fileExtension: String,
        writer: (URL) async throws -> Void
    ) async throws -> URL {
        let baseName = baseFilename(meeting: meeting, content: content, fileExtension: fileExtension)
        let firstCandidate = folder.appendingPathComponent("\(baseName).\(fileExtension)")
        if try await write(toReservedFileAt: firstCandidate, writer: writer) {
            return firstCandidate
        }

        for index in 2...Self.maxCollisionAttempts {
            let candidate = folder.appendingPathComponent("\(baseName)-\(index).\(fileExtension)")
            if try await write(toReservedFileAt: candidate, writer: writer) {
                return candidate
            }
        }

        let fallback = folder.appendingPathComponent("\(baseName)-\(UUID().uuidString).\(fileExtension)")
        guard try await write(toReservedFileAt: fallback, writer: writer) else {
            throw CocoaError(.fileWriteFileExists)
        }
        return fallback
    }

    private func write(toReservedFileAt url: URL, writer: (URL) async throws -> Void) async throws -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard descriptor >= 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(descriptor)

        do {
            try await writer(url)
            return true
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    /// Atomically reserves a path before writing so concurrent exports cannot
    /// choose the same destination after a preflight existence check.
    private func write(_ data: Data, toNewFileAt url: URL) throws -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard descriptor >= 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return true
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private static let maxCollisionAttempts = 1000

    private func baseFilename(
        meeting: MeetingRecord,
        content: MeetingExportContent,
        fileExtension: String
    ) -> String {
        let filename = MeetingExporter.suggestedFilename(meeting: meeting, content: content, fileExtension: fileExtension)
        let stem = (filename as NSString).deletingPathExtension
        if let datePrefix = Self.datePrefix(from: meeting.startTime) {
            return "\(datePrefix)-\(stem)"
        }
        return stem
    }

    private static func datePrefix(from startTime: String) -> String? {
        guard let date = MeetingBrowserLogic.parseDate(startTime) else { return nil }
        return fileDateFormatter.string(from: date)
    }

    // MARK: - Logging

    /// Blocks until all queued log writes have drained. Intended for tests that
    /// assert on log file contents after a synchronous `performExport` call.
    func waitForPendingLogWrites() {
        logQueue.sync {}
    }

    private func writeLog(_ message: String) {
        let line = "[\(Self.isoFormatter.string(from: dateProvider()))] \(message)\n"
        Self.logger.log("\(line, privacy: .private)")

        logQueue.async { [self] in
            do {
                try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: logURL.path) {
                    guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                fputs("[markdown-auto-export] log write failed: \(error)\n", stderr)
            }
        }
    }

    // MARK: - Formatters

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
