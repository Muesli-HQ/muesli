import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Cotypist (experimental): local typeahead delivered through an input method.
///
/// The embedded input-method helper (`Contents/Library/Input Methods/MuesliCotypist.app`) owns
/// keys, the inline ghost (marked text) and insertion, and needs no permissions. It asks this
/// service — inside Muesli, which already holds Accessibility and Screen Recording — for each
/// suggestion over a Unix socket in the app's support directory. Muesli gathers context, runs
/// the base model and gates the result, and journals what happened to every suggestion shown.
@MainActor
final class CotypistService {
    static let shared = CotypistService()

    /// Set by MuesliController: screenshots conflict with meeting system-audio capture (SCStream).
    var isScreenCaptureAllowed: () -> Bool = { true }

    private var server: CotypistSocketServer?
    private var engineTask: Task<CotypistEngine, Error>?
    /// Screen OCR per app, refreshed in the background through the dictation context plumbing.
    private var screenText: [String: (text: String, at: Date)] = [:]
    private var screenInFlight: Set<String> = []

    static var socketURL: URL { AppIdentity.supportDirectoryURL.appendingPathComponent("cotypist.sock") }
    static var journalURL: URL { AppIdentity.supportDirectoryURL.appendingPathComponent("cotypist-suggestions.jsonl") }

    func start() {
        guard server == nil else { return }
        registerInputSource()
        do {
            server = try CotypistSocketServer(path: Self.socketURL.path) { [weak self] request in
                await self?.handle(request) ?? [:]
            }
            log("listening on \(Self.socketURL.path)")
        } catch {
            log("socket server failed: \(error)")
        }
    }

    // MARK: - Input source

    /// Installs the embedded input method into ~/Library/Input Methods and registers it. Text Input
    /// Sources only discovers input methods there, and System Settings doesn't list one reached
    /// through a symlink, so it's a copy (about 100 KB), refreshed when the app's build changes.
    /// Enabling and selecting stay with the user: macOS doesn't persist an input source enabled
    /// from code, and refuses programmatic selection of a third-party one.
    private func registerInputSource() {
        let fileManager = FileManager.default
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Input Methods/MuesliCotypist.app")
        guard fileManager.fileExists(atPath: embedded.path) else { log("input method not bundled"); return }
        let folder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods")
        let installed = folder.appendingPathComponent("\(AppIdentity.displayName) Cotypist.app")
        let executable = "Contents/MacOS/MuesliCotypist"
        let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: installed.path)) != nil
        let upToDate = !isSymlink && fileManager.contentsEqual(
            atPath: embedded.appendingPathComponent(executable).path,
            andPath: installed.appendingPathComponent(executable).path
        ) && fileManager.contentsEqual(
            atPath: embedded.appendingPathComponent("Contents/Info.plist").path,
            andPath: installed.appendingPathComponent("Contents/Info.plist").path
        )
        if !upToDate {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                try? fileManager.removeItem(at: installed)
                try fileManager.copyItem(at: embedded, to: installed)
            } catch {
                log("input method install failed: \(error)")
                return
            }
            // A running helper keeps the old code; macOS relaunches it on the next keystroke.
            let helperID = (Bundle.main.bundleIdentifier ?? "com.muesli.app") + ".inputmethod.Cotypist"
            NSRunningApplication.runningApplications(withBundleIdentifier: helperID).forEach { $0.forceTerminate() }
        }
        let status = TISRegisterInputSource(installed as CFURL)
        log("registered input method (status \(status), \(upToDate ? "up to date" : "installed"))")
    }

    // MARK: - Requests

    private func handle(_ request: [String: Any]) async -> [String: Any] {
        switch request["type"] as? String {
        case "suggest": return await suggest(request)
        case "outcome":
            journal(request)
            return [:]
        default: return ["rejection": "unknown request"]
        }
    }

    private func suggest(_ request: [String: Any]) async -> [String: Any] {
        let bundleID = request["app"] as? String ?? ""
        let midWord = request["midWord"] as? Bool ?? false
        let afterSpace = request["afterSpace"] as? Bool ?? false
        let firstWordOnly = request["firstWordOnly"] as? Bool ?? false

        var (fieldText, source) = context(bundleID: bundleID, field: request["field"] as? String,
                                          typed: request["typed"] as? String ?? "")
        guard !fieldText.isEmpty else { return ["rejection": "no context", "source": source] }

        // Mid-word: split off the half-typed word for token healing.
        var heal: String?
        if midWord {
            guard let split = Self.splitPartialWord(fieldText) else { return ["rejection": "mid-word: no partial word"] }
            (fieldText, heal) = (split.before, split.heal)
        }

        // Screen OCR, label-free ahead of the typed text: a base model reads it as earlier parts of
        // the same document. Only when the field itself says little, and never where the context
        // already carries the conversation (an agent prompt in a terminal).
        var prompt = fieldText.trimmingCharacters(in: .whitespaces)
        refreshScreenIfNeeded(bundleID: bundleID)
        if prompt.count < 200, source != "agent-prompt", let screen = screenText[bundleID]?.text, !screen.isEmpty {
            prompt = screen + "\n\n" + prompt
            source += "+ocr"
        }
        guard prompt.count >= 3 else { return ["rejection": "too little context", "source": source] }

        do {
            let engine = try await loadEngine()
            let maxTokens = firstWordOnly ? 4 : 10
            let completion = try await engine.complete(prompt: prompt, maxTokens: maxTokens, heal: heal)
            let timing: [String: Any] = ["source": source, "modelMs": Int(completion.promptMs + completion.decodeMs)]
            switch CotypistShaper.shape(completion, afterSpace: afterSpace, heal: heal, maxTokens: maxTokens, firstWordOnly: firstWordOnly) {
            case .success(let shaped):
                return timing.merging(["text": shaped.text, "firstWordLogProb": shaped.firstWordLogProb]) { $1 }
            case .failure(let rejection):
                return timing.merging(["rejection": rejection.description]) { $1 }
            }
        } catch {
            return ["rejection": "engine: \(error.localizedDescription)", "source": source]
        }
    }

    private func loadEngine() async throws -> CotypistEngine {
        if let engineTask { return try await engineTask.value }
        let task = Task { () throws -> CotypistEngine in
            let start = Date()
            let engine = try await CotypistEngine()
            // Warm the kernels and the healing vocabulary so the first real suggestion isn't the slow one.
            _ = try await engine.complete(prompt: "Thanks for the", maxTokens: 2, heal: " qui")
            await MainActor.run { self.log(String(format: "engine ready in %.1fs", Date().timeIntervalSince(start))) }
            return engine
        }
        engineTask = task
        do { return try await task.value } catch { engineTask = nil; throw error }
    }

    // MARK: - Context

    /// The text before the caret: the field's own text when the client hands it over; otherwise the
    /// dictation context capture (Accessibility, read further back) — for a terminal, Claude Code's
    /// prompt box plus the conversation above it when it's on screen; else the helper's keystrokes.
    private func context(bundleID: String, field: String?, typed: String) -> (String, String) {
        if let field, !field.isEmpty { return (field, "field") }
        let captured = DictationContextCapture.capture(allowTitleFallback: false, maxDocumentChars: 1500)
        let document = captured.bundleID == bundleID ? captured.documentContext : ""
        if let prompt = CotypistAgentPrompt.context(screen: document) { return (prompt, "agent-prompt") }
        if !document.isEmpty { return (document, "accessibility") }
        // Why the fallback: permission, the frontmost app, how much text it exposed (lengths only).
        return (typed, "keystrokes(ax=\(AXIsProcessTrusted()) front=\(captured.bundleID) text=\(captured.documentContext.count))")
    }

    /// Refreshes screen OCR for `bundleID` off the typing path, at most every 20 s, through the same
    /// capture dictation uses: OCR only when it belongs to the focused app and document, and never
    /// while a meeting records (screenshots break its system-audio capture).
    private func refreshScreenIfNeeded(bundleID: String) {
        guard !bundleID.isEmpty, !screenInFlight.contains(bundleID),
              Date().timeIntervalSince(screenText[bundleID]?.at ?? .distantPast) > 20 else { return }
        screenInFlight.insert(bundleID)
        Task { @MainActor in
            let captured = await DictationContextCapture.capture(
                includeScreenOCR: true,
                shouldCaptureScreenOCR: { await MainActor.run { CotypistService.shared.isScreenCaptureAllowed() } },
                allowTitleFallback: false
            )
            screenInFlight.remove(bundleID)
            let text = captured.bundleID == bundleID ? Self.promptReadyScreenText(captured.ocrText) : ""
            screenText[bundleID] = (text, Date())
            log("OCR app=\(bundleID) \(text.count) chars")  // lengths only: on-screen text isn't the user's own
        }
    }

    /// Splits a half-typed word (2+ characters) off the end of `text` for token healing. After a
    /// space the space travels with the word, as the model tokenizes it; at the start of the text or
    /// a line the word stands alone.
    static func splitPartialWord(_ text: String) -> (before: String, heal: String)? {
        let start = text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        let partial = String(text[start...])
        guard partial.count >= 2 else { return nil }
        if start > text.startIndex, text[text.index(before: start)] == " " {
            return (String(text[..<text.index(before: start)]), " " + partial)
        }
        return (String(text[..<start]), partial)
    }

    /// OCR comes back as a column of short lines (labels, buttons, chat rows); fed as-is, a base model
    /// expects another short line and predicts a line break. Keep lines of 3+ words, nearest the
    /// bottom of the window (the conversation or document around an input box), as flowing text.
    static func promptReadyScreenText(_ ocr: String, maxCharacters: Int = 600) -> String {
        let lines = ocr.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.split(separator: " ").count >= 3 }
        var kept: [String] = []
        var length = 0
        for line in lines.reversed() {
            guard length + line.count <= maxCharacters else { break }
            kept.insert(line, at: 0)
            length += line.count + 1
        }
        return kept.joined(separator: " ")
    }

    // MARK: - Journal

    /// One line per suggestion shown and its outcome — suggestion text only, never the user's text.
    private func journal(_ record: [String: Any]) {
        var entry = record
        entry.removeValue(forKey: "type")
        entry["ts"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        let url = Self.journalURL
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data + Data("\n".utf8))
        try? handle.close()
    }

    private func log(_ message: String) {
        fputs("[cotypist] \(message)\n", stderr)
    }
}

/// Claude Code's input box in a terminal screen (`────` / `❯ text` / `────`), plus the
/// conversation above it — the context for cmux, which gives input methods no text.
enum CotypistAgentPrompt {
    static func context(screen: String) -> String? {
        let lines = screen.components(separatedBy: "\n").suffix(120).map { $0 }
        for i in stride(from: lines.count - 1, through: 1, by: -1) {
            guard isPrompt(lines[i]), isRule(lines[i - 1]) else { continue }
            var typed = String(lines[i].dropFirst(2))
            var j = i + 1
            while j < lines.count, !isRule(lines[j]) {
                typed += String(lines[j].dropFirst(2))
                j += 1
            }
            guard j < lines.count else { return nil }
            // Terminals pad lines to their width; beyond a single space it's padding.
            while typed.hasSuffix("  ") { typed.removeLast() }
            let above = lines[max(0, i - 41)..<(i - 1)]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return above.joined(separator: "\n") + "\n\n" + typed
        }
        return nil
    }

    static func isRule(_ line: String) -> Bool {
        let body = line.trimmingCharacters(in: .whitespaces)
        return body.count >= 10 && body.allSatisfy { $0 == "─" }
    }

    static func isPrompt(_ line: String) -> Bool {
        let characters = Array(line.prefix(2))
        return characters.count == 2 && characters[0] == "❯" && (characters[1] == " " || characters[1] == "\u{00A0}")
    }
}
