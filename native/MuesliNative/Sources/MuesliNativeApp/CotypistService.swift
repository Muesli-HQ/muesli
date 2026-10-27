import AppKit
import ApplicationServices
import Carbon
import Foundation
import MuesliCore
import Security

/// Cotypist (experimental): local typeahead delivered through an input method.
///
/// The embedded input-method helper (`Contents/Library/Input Methods/MuesliCotypist.app`) owns
/// keys, the inline ghost (marked text) and insertion, and needs no permissions. It asks this
/// service — inside Muesli, which already holds Accessibility and Screen Recording — for each
/// suggestion over a Unix socket in the app's support directory. Muesli gathers context, runs
/// the base model and gates the result, and records what happened to every suggestion shown in
/// the local database (accepted ones also appear in the timeline).
@MainActor
final class CotypistService {
    static let shared = CotypistService()

    /// Set by MuesliController: screenshots conflict with meeting system-audio capture (SCStream).
    /// Closed until the controller says otherwise.
    var isScreenCaptureAllowed: () -> Bool = { false }
    /// Set by MuesliController: the user's Cotypist settings, read on every request.
    var config: () -> AppConfig = { AppConfig() }
    /// Set by MuesliController: where suggestion outcomes are recorded.
    var store: DictationStore?
    /// Called after an accepted suggestion is recorded, to refresh the timeline.
    var onAccepted: () -> Void = {}

    private var server: CotypistSocketServer?
    private var engineTask: Task<CotypistEngine, Error>?
    /// Screen OCR per app with the document it was read from, refreshed in the background through
    /// the dictation context plumbing. Used only while that document is still the focused one.
    private var screenText: [String: (text: String, at: Date, document: String?)] = [:]
    private var screenInFlight: Set<String> = []
    /// The text before the caret for recent suggestions, keyed by app and suggestion text, so an
    /// outcome can be recorded with the sentence it completed.
    private var recentContexts: [(key: String, before: String)] = []

    static var socketURL: URL { AppIdentity.supportDirectoryURL.appendingPathComponent("cotypist.sock") }

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
    /// through a symlink, so it's a copy (about 100 KB), refreshed when the app's build or signature
    /// changes. The copy is registered only if its code signature is valid and matches the
    /// embedded helper's designated requirement (same signer as this build).
    /// Enabling and selecting stay with the user: macOS doesn't persist an input source enabled
    /// from code, and refuses programmatic selection of a third-party one.
    private func registerInputSource() {
        let fileManager = FileManager.default
        let embedded = CotypistSetup.embeddedInputMethodURL
        guard fileManager.fileExists(atPath: embedded.path) else { log("input method not bundled"); return }
        let folder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods")
        let installed = folder.appendingPathComponent("\(AppIdentity.displayName) Cotypist.app")
        let executable = "Contents/MacOS/MuesliCotypist"
        let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: installed.path)) != nil
        let upToDate = !isSymlink && [executable, "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"].allSatisfy {
            fileManager.contentsEqual(atPath: embedded.appendingPathComponent($0).path,
                                      andPath: installed.appendingPathComponent($0).path)
        }
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
        guard Self.hasValidSignature(installed, likeEmbedded: embedded) else {
            log("input method copy failed signature validation; not registered")
            return
        }
        let status = TISRegisterInputSource(installed as CFURL)
        log("registered input method (status \(status), \(upToDate ? "up to date" : "installed"))")
    }

    /// The installed copy's signature is intact and satisfies the embedded helper's designated
    /// requirement, so a modified or foreign bundle at that path is never registered.
    private static func hasValidSignature(_ installed: URL, likeEmbedded embedded: URL) -> Bool {
        var embeddedCode: SecStaticCode?, installedCode: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(embedded as CFURL, [], &embeddedCode) == errSecSuccess, let embeddedCode,
              SecCodeCopyDesignatedRequirement(embeddedCode, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode) == errSecSuccess, let installedCode
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(installedCode, flags, requirement) == errSecSuccess
    }

    // MARK: - Requests

    private func handle(_ request: [String: Any]) async -> [String: Any] {
        switch request["type"] as? String {
        case "suggest": return await suggest(request)
        case "outcome":
            record(request)
            return [:]
        default: return ["rejection": "unknown request"]
        }
    }

    /// Every reply carries the settings the helper applies itself, so changes reach it with the
    /// next suggestion: the pause before completing a word (0 when that's off).
    private func suggest(_ request: [String: Any]) async -> [String: Any] {
        let config = config()
        let helperSettings: [String: Any] = ["midWordDelay": config.cotypistCompleteWords ? config.cotypistWordPause.seconds : 0]
        return helperSettings.merging(await suggestion(request, config: config)) { $1 }
    }

    private func suggestion(_ request: [String: Any], config: AppConfig) async -> [String: Any] {
        let bundleID = request["app"] as? String ?? ""
        let midWord = request["midWord"] as? Bool ?? false
        let afterSpace = request["afterSpace"] as? Bool ?? false
        let firstWordOnly = request["firstWordOnly"] as? Bool ?? false
        if config.cotypistDisabledApps.contains(bundleID) { return ["rejection": "off in this app"] }
        guard CotypistModel.isDownloaded else { return ["rejection": "model not downloaded"] }
        if midWord && !config.cotypistCompleteWords { return ["rejection": "completing words is off"] }
        let thresholds = CotypistShaper.Thresholds(firstWord: config.cotypistFrequency.firstWordGate(midWord: midWord),
                                                   maxWords: config.cotypistSuggestionLength.maxWords)

        var (fieldText, source, document) = await context(bundleID: bundleID, field: request["field"] as? String,
                                                          typed: request["typed"] as? String ?? "")
        guard !fieldText.isEmpty else { return ["rejection": "no context", "source": source] }
        let textBeforeCaret = fieldText

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
        if config.cotypistUseScreenContext, prompt.count < 200, source != "agent-prompt" {
            if document == nil { document = await Self.focused().documentIdentifier }
            refreshScreenIfNeeded(bundleID: bundleID, document: document)
            if let screen = screenText[bundleID], screen.document == document, !screen.text.isEmpty {
                prompt = screen.text + "\n\n" + prompt
                source += "+ocr"
            }
        }
        guard prompt.count >= 3 else { return ["rejection": "too little context", "source": source] }

        do {
            let engine = try await loadEngine()
            let maxTokens = firstWordOnly ? 4 : 10
            let completion = try await engine.complete(prompt: prompt, maxTokens: maxTokens, heal: heal)
            let timing: [String: Any] = ["source": source, "modelMs": Int(completion.promptMs + completion.decodeMs)]
            switch CotypistShaper.shape(completion, afterSpace: afterSpace, heal: heal, maxTokens: maxTokens,
                                        firstWordOnly: firstWordOnly, thresholds: thresholds) {
            case .success(let shaped):
                remember(before: textBeforeCaret, app: bundleID, suggestion: shaped.text)
                // With one-word suggestions the first stage is the whole suggestion.
                let complete = firstWordOnly && thresholds.maxWords == 1
                return timing.merging(["text": shaped.text, "firstWordLogProb": shaped.firstWordLogProb,
                                       "complete": complete]) { $1 }
            case .failure(let rejection):
                // `retryFull`: the first word ran past the first stage's budget; the full request may finish it.
                return timing.merging(["rejection": rejection.description, "retryFull": rejection == .firstWordIncomplete]) { $1 }
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
    /// Also returns the focused document's identity when it was read, for binding screen OCR to it.
    private func context(bundleID: String, field: String?, typed: String) async -> (String, String, String?) {
        if let field, !field.isEmpty { return (field, "field", nil) }
        let captured = await Self.focused()
        let text = captured.bundleID == bundleID ? captured.documentContext : ""
        if let prompt = CotypistAgentPrompt.context(screen: text) { return (prompt, "agent-prompt", captured.documentIdentifier) }
        if !text.isEmpty { return (text, "accessibility", captured.documentIdentifier) }
        // Why the fallback: permission, the frontmost app, how much text it exposed (lengths only).
        return (typed, "keystrokes(ax=\(AXIsProcessTrusted()) front=\(captured.bundleID) text=\(captured.documentContext.count))",
                captured.documentIdentifier)
    }

    /// The focused app's text before the caret and its document identity (window title when it has
    /// no document), read through Accessibility off the main actor: a slow app can't stall Muesli.
    private static func focused() async -> DictationContext {
        await Task.detached(priority: .userInitiated) {
            DictationContextCapture.capture(allowTitleFallback: true, maxDocumentChars: 1500)
        }.value
    }

    /// Refreshes screen OCR for `bundleID` off the typing path through the same capture dictation
    /// uses: when the focused document changed, else at most every 20 s. OCR only when it belongs
    /// to the focused app and document, and never while a meeting records (screenshots break its
    /// system-audio capture).
    private func refreshScreenIfNeeded(bundleID: String, document: String?) {
        let cached = screenText[bundleID]
        guard !bundleID.isEmpty, !screenInFlight.contains(bundleID),
              cached == nil || cached?.document != document || Date().timeIntervalSince(cached!.at) > 20 else { return }
        screenInFlight.insert(bundleID)
        Task { @MainActor in
            let captured = await DictationContextCapture.capture(
                includeScreenOCR: true,
                shouldCaptureScreenOCR: { await MainActor.run { CotypistService.shared.isScreenCaptureAllowed() } },
                allowTitleFallback: true
            )
            screenInFlight.remove(bundleID)
            let text = captured.bundleID == bundleID ? Self.promptReadyScreenText(captured.ocrText) : ""
            screenText[bundleID] = (text, Date(), captured.documentIdentifier)
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

    // MARK: - History

    /// Records a suggestion's outcome: the suggestion, what was accepted of it, and the sentence it
    /// continued (the user's own text, kept to that one sentence, in the local database only).
    private func record(_ message: [String: Any]) {
        let key = Self.contextKey(app: message["app"] as? String ?? "", suggestion: message["text"] as? String ?? "")
        let before = recentContexts.last { $0.key == key }?.before ?? ""
        guard let store, let event = Self.event(from: message, contextBefore: Self.sentence(endingAt: before)) else { return }
        // A SQLite write transaction: off the main actor, which only hears back to refresh the timeline.
        Task.detached(priority: .utility) {
            do {
                try store.recordCotypistSuggestion(event)
                if !event.acceptedText.isEmpty { await MainActor.run { CotypistService.shared.onAccepted() } }
            } catch {
                fputs("[cotypist] could not record suggestion: \(error)\n", stderr)
            }
        }
    }

    private func remember(before: String, app: String, suggestion: String) {
        recentContexts.append((Self.contextKey(app: app, suggestion: suggestion), before))
        if recentContexts.count > 16 { recentContexts.removeFirst(recentContexts.count - 16) }
    }

    private static func contextKey(app: String, suggestion: String) -> String { app + "\n" + suggestion }

    /// The sentence being written at the caret, for showing where a suggestion was accepted: from
    /// the last sentence end (or line break), reaching back one more sentence when the current one
    /// has only just started, and at most `maxCharacters`, cut at a word.
    static func sentence(endingAt text: String, maxCharacters: Int = 120) -> String {
        var line = String(text.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        // Sentence starts: just after ". ", "! " or "? ".
        var starts: [String.Index] = [line.startIndex]
        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            if ".!?".contains(line[index]), next < line.endIndex, line[next] == " " { starts.append(line.index(after: next)) }
            index = next
        }
        let current = starts.last!
        let start = line[current...].split(separator: " ").count >= 3 ? current : starts[max(starts.count - 2, 0)]
        line = String(line[start...]).trimmingCharacters(in: .newlines)
        guard line.count > maxCharacters else { return line.drop { $0 == " " }.description }
        let tail = line.suffix(maxCharacters)
        let word = tail.firstIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
        return "…" + tail[word...]
    }

    static func event(from message: [String: Any], contextBefore: String = "", date: Date = Date()) -> CotypistSuggestionEvent? {
        guard let text = message["text"] as? String, !text.isEmpty,
              let outcome = CotypistSuggestionEvent.Outcome(rawValue: message["outcome"] as? String ?? "") else { return nil }
        let bundleID = message["app"] as? String ?? ""
        func int(_ key: String) -> Int? { (message[key] as? NSNumber)?.intValue }
        return CotypistSuggestionEvent(
            date: date,
            appBundleID: bundleID,
            appName: appName(bundleID: bundleID),
            trigger: message["trigger"] as? String ?? "boundary",
            suggestionText: text,
            acceptedText: message["accepted"] as? String ?? (outcome == .accepted ? text : ""),
            contextBefore: contextBefore,
            outcome: outcome,
            firstWordLogProb: (message["first_word_logprob"] as? NSNumber)?.doubleValue,
            firstMs: int("first_ms"),
            fullMs: int("full_ms"),
            contextSource: message["source"] as? String ?? "",
            model: CotypistModel.repoID
        )
    }

    /// The app's name as the user knows it; empty (no name or icon shown) when it can't be found,
    /// never the bundle ID.
    private static func appName(bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
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
