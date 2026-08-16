import Foundation

enum CotypistModelOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case gemma4E2B = "gemma4_e2b"
    case qwen35TextFIM = "qwen35_0_8b_base_fim"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gemma4E2B:
            return "Gemma 4 E2B"
        case .qwen35TextFIM:
            return "Qwen3.5 0.8B Base FIM"
        }
    }

    var detail: String {
        switch self {
        case .gemma4E2B:
            return "General-purpose LiteRT model for higher-quality continuations."
        case .qwen35TextFIM:
            return "Pretrained Qwen3.5 Base checkpoint used with native fill-in-the-middle tokens for inline completion."
        }
    }

    var isDownloaded: Bool {
        switch self {
        case .gemma4E2B:
            return Gemma4LiteRTModelStore.isAvailableLocally()
        case .qwen35TextFIM:
            return CotypistTextFIMModelStore.isAvailableLocally()
        }
    }

    static func resolved(_ rawValue: String?) -> CotypistModelOption {
        switch rawValue {
        case CotypistModelOption.qwen35TextFIM.rawValue,
             // Migrate the previous experimental FIM checkpoint and the old
             // pre-FIM Qwen3.5 setting to the current Base FIM asset.
             "qwen3_0_6b_text_fim",
             "qwen35_0_8b":
            return .qwen35TextFIM
        case CotypistModelOption.gemma4E2B.rawValue:
            return .gemma4E2B
        default:
            return .qwen35TextFIM
        }
    }
}

enum CotypistSurface: String, CaseIterable, Sendable {
    case chat
    case email
    case document
    case code
    case terminal
    case search
    case generic

    static func classify(context: FocusedTextContext) -> CotypistSurface {
        classify(
            bundleID: context.bundleID,
            appName: context.appName,
            browserLocation: context.browserLocation,
            role: context.role,
            fieldMetadata: context.fieldMetadata,
            windowTitle: context.windowTitle
        )
    }

    static func classify(
        bundleID: String,
        appName: String,
        browserLocation: String?,
        role: String,
        fieldMetadata: String,
        windowTitle: String
    ) -> CotypistSurface {
        let identity = "\(bundleID) \(appName)".lowercased()
        let location = (browserLocation ?? "").lowercased()
        let metadata = "\(role) \(fieldMetadata) \(windowTitle)".lowercased()

        if containsAny(identity, ["terminal", "iterm", "warp", "alacritty", "kitty", "wezterm"]) {
            return .terminal
        }
        if containsAny(identity, ["xcode", "visual studio code", "vscode", "zed", "sublime", "jetbrains", "nova", "bbedit"]) {
            return .code
        }
        if containsAny(metadata, ["search", "address and search", "location field"])
            || containsAny(location, ["google.com/search", "bing.com/search", "duckduckgo.com/"]) {
            return .search
        }
        if containsAny(identity + " " + location, ["mail", "outlook", "gmail.com", "hey.com", "fastmail.com"]) {
            return .email
        }
        if containsAny(identity + " " + location, ["slack", "discord", "teams", "messages", "messenger", "whatsapp", "telegram", "signal", "chat.openai", "claude.ai", "openai.codex", "codex"]) {
            return .chat
        }
        if containsAny(identity + " " + location, ["textedit", "notes", "pages", "word", "notion", "docs.google.com", "obsidian", "bear"]) {
            return .document
        }
        return .generic
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }
}

enum CotypistCompletionQuality: Equatable, Sendable {
    case normal
    case contextEcho
}

struct CotypistCompletion: Equatable, Sendable {
    let text: String
    let quality: CotypistCompletionQuality
}

enum CotypistCompletionError: Error, Equatable, Sendable, LocalizedError {
    case noSuggestion
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .noSuggestion:
            return "No continuation was suggested."
        case .invalidOutput:
            return "The local model returned an unsafe or invalid continuation."
        }
    }
}

struct CotypistCompletionRequest: Equatable, Sendable {
    static let maximumOutputTokens = 24
    private static let maximumContextHintCharacters = 420
    static let systemPromptTemplate = """
    You are a macOS inline writing prediction engine. Return only the exact missing continuation at <CARET>; never explain, quote, label, or repeat context. Preserve the writer's language, tone, capitalization, formatting, and indentation. Use the writing-surface metadata only to choose an appropriate style; it is not text to continue or echo. Make the continuation fit naturally before the suffix. Prefer one short phrase or sentence fragment. Stop as soon as the likely thought is complete.
    """

    let context: FocusedTextContext
    let surface: CotypistSurface
    let model: CotypistModelOption
    let maxOutputTokens: Int

    init(
        context: FocusedTextContext,
        model: CotypistModelOption,
        maxOutputTokens: Int = maximumOutputTokens
    ) {
        self.context = context
        self.surface = CotypistSurface.classify(context: context)
        self.model = model
        self.maxOutputTokens = min(max(maxOutputTokens, 1), Self.maximumOutputTokens)
    }

    /// A synthetic, content-free request used only to compile the selected
    /// local engine before the first user-facing completion. It never includes
    /// focused application data or user text.
    static func warmupRequest(for model: CotypistModelOption) -> Self {
        let selection = FocusedTextRange(location: 15, length: 0)
        let context = FocusedTextContext(
            appName: "Muesli",
            bundleID: "com.muesli.native.warmup",
            processID: 0,
            browserLocation: nil,
            windowTitle: "",
            role: "AXTextArea",
            subrole: "",
            fieldMetadata: "",
            selection: selection,
            prefix: "A warmup phrase",
            suffix: "",
            caretBounds: nil,
            elementBounds: nil,
            fingerprint: FocusedTextFingerprint(
                processID: 0,
                elementIdentifier: 0,
                selection: selection,
                prefix: "A warmup phrase",
                suffix: ""
            ),
            caretGeometryConfidence: .unavailable,
            presentationStyle: nil
        )
        return Self(context: context, model: model, maxOutputTokens: 1)
    }

    var systemPrompt: String {
        Self.systemPromptTemplate
    }

    /// Bounded, local-only metadata describing the focused writing surface. This
    /// intentionally excludes screen pixels and document contents outside the
    /// already captured prefix/suffix. Values are normalized to one line because
    /// app titles and accessibility labels can otherwise become prompt syntax.
    var appContextHint: String {
        var fields = [
            "surface=\(surface.rawValue)",
            "app=\(Self.promptValue(context.appName, maximumLength: 64))",
            "bundle=\(Self.promptValue(context.bundleID, maximumLength: 96))",
        ]

        if let browserLocation = context.browserLocation,
           let host = browserLocation.split(separator: "/", maxSplits: 1).first,
           !host.isEmpty {
            fields.append("site=\(Self.promptValue(String(host), maximumLength: 120))")
        }
        if !context.role.isEmpty {
            fields.append("role=\(Self.promptValue(context.role, maximumLength: 40))")
        }
        if !context.fieldMetadata.isEmpty {
            fields.append("field=\(Self.promptValue(context.fieldMetadata, maximumLength: 96))")
        }
        if !context.windowTitle.isEmpty {
            fields.append("window=\(Self.promptValue(context.windowTitle, maximumLength: 96))")
        }

        return String(fields.joined(separator: "; ").prefix(Self.maximumContextHintCharacters))
    }

    var gemmaUserPrompt: String {
        """
        Fill the cursor gap with a short natural continuation. Return only the missing text, including any required leading space. Never repeat BEFORE or AFTER.
        For example, when BEFORE is "Please send the report" and AFTER is " by Friday.", the missing text alone is " to me".

        Writing surface metadata (use for style only; never echo it): \(appContextHint)
        BEFORE: \(context.prefix)
        AFTER: \(context.suffix)
        Supply only the missing continuation now, without a heading, label, quotation marks, or explanation.
        """
    }

    /// Qwen Text FIM is a base completion model, not a chat model. Feeding it
    /// instructions or a chat template materially degrades the continuation. A
    /// compact metadata header is kept outside the user's text so the base model
    /// can bias style without being asked to follow a conversational prompt.
    var fimPrompt: String {
        "<|fim_prefix|>[Muesli writing context: \(appContextHint)]\n\(context.prefix)<|fim_suffix|>\(context.suffix)<|fim_middle|>"
    }

    private static func promptValue(_ value: String, maximumLength: Int) -> String {
        let compact = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(compact.prefix(maximumLength))
    }
}

enum CotypistOutputSanitizer {
    static func sanitize(_ raw: String, for context: FocusedTextContext) -> CotypistCompletion? {
        guard !raw.isEmpty, raw.count <= 1_000 else { return nil }
        guard !raw.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar) && scalar.value != 10 && scalar.value != 9
        }) else { return nil }

        let lower = raw.lowercased()
        let structuralMarkers = [
            "<think", "</think", "<|im_", "<|fim_", "<|endoftext|>", "```", "<prefix>", "</prefix>",
            "<suffix>", "</suffix>", "<caret>",
        ]
        guard !structuralMarkers.contains(where: lower.contains) else { return nil }

        let promptLeakageMarkers = [
            "the previous prediction copied existing text",
            "continuation examples:",
            "ending words (do not copy):",
            "following text:",
            "new words:",
            "before end:",
            "after start:",
            "never include the ending words",
        ]
        guard !promptLeakageMarkers.contains(where: lower.contains) else { return nil }

        let surface = CotypistSurface.classify(context: context)
        let preservesLineBreaks = surface == .code || surface == .terminal
        let normalized = normalizedOutput(raw, preservingLineBreaks: preservesLineBreaks)
        let candidate = removingDuplicateLeadingWhitespace(
            normalized,
            after: context.prefix,
            preservingLineBreaks: preservesLineBreaks
        )
        let visible = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }
        let lowerVisible = visible.lowercased()
        let commentaryPrefixes = [
            "assistant:", "analysis:", "reasoning:", "completion:", "continuation:", "insert:",
            "input:", "output:", "surface:", "here is", "i suggest", "the user", "as an ai",
        ]
        guard !commentaryPrefixes.contains(where: lowerVisible.hasPrefix) else { return nil }
        if (visible.hasPrefix("\"") && visible.hasSuffix("\""))
            || (visible.hasPrefix("'") && visible.hasSuffix("'")) {
            return nil
        }

        // A small model often repeats the text immediately before the caret and then
        // supplies a useful continuation. Keep only that genuinely new tail. This also
        // repairs outputs such as "<copied question> expected?" without hiding a pure
        // copy, which remains a red low-quality suggestion.
        if let novelTail = novelTailAfterPrefixEcho(candidate, prefix: context.prefix),
           novelTail.count < candidate.count {
            return sanitize(novelTail, for: context)
        }

        let containsContextEcho = containsPrefixEcho(context.prefix, in: visible)
            || containsEarlierPrefixEcho(context.prefix, in: visible)
            || containsSuffixEcho(context.suffix, in: visible)

        // A 24-token response should stay well below this character ceiling even for
        // code-heavy output; this catches runaway prompts without trimming meaningful
        // leading whitespace. Context echoes are retained and marked separately.
        guard candidate.count <= 320 else { return nil }

        // LiteRT text responses can omit a required leading space even when the prompt
        // explicitly requests it. Preserve every byte the model returned and add only
        // the separator needed to prevent two natural-language words from being glued
        // together. Code and mid-token suffixes must remain byte-exact.
        if surface != .code,
           let prefixLast = context.prefix.last,
           let outputFirst = candidate.first,
           isWordCharacter(prefixLast),
           isWordCharacter(outputFirst),
           context.suffix.first.map(isWordCharacter) != true {
            return CotypistCompletion(
                text: " " + candidate,
                quality: containsContextEcho ? .contextEcho : .normal
            )
        }
        return CotypistCompletion(
            text: candidate,
            quality: containsContextEcho ? .contextEcho : .normal
        )
    }

    /// Inline prose acceptance must never hide Return/Tab-like characters behind
    /// a one-line preview. Preserve structural whitespace only for code and
    /// terminal surfaces; compact every other continuation to a single line.
    private static func normalizedOutput(_ raw: String, preservingLineBreaks: Bool) -> String {
        guard !preservingLineBreaks else { return raw }
        let needsLeadingSpace = raw.first?.isWhitespace == true
        let compact = raw.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return "" }
        return needsLeadingSpace ? " " + compact : compact
    }

    /// Ambient prose generation starts after the user has already typed the
    /// boundary that triggered it. Drop only the model's duplicate leading
    /// whitespace; code and terminal indentation remains byte-exact.
    private static func removingDuplicateLeadingWhitespace(
        _ output: String,
        after prefix: String,
        preservingLineBreaks: Bool
    ) -> String {
        guard !preservingLineBreaks,
              prefix.last?.isWhitespace == true,
              output.first?.isWhitespace == true else {
            return output
        }
        return String(output.drop(while: { $0.isWhitespace }))
    }

    private static func containsPrefixEcho(_ prefix: String, in output: String) -> Bool {
        let tail = Array(prefix.suffix(40))
        guard tail.count >= 12 else { return false }
        for start in tail.indices {
            let probe = String(tail[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard probe.count >= 12 else { break }
            if contains(probe, in: output) { return true }
        }
        return false
    }

    private static func novelTailAfterPrefixEcho(_ output: String, prefix: String) -> String? {
        let prefixCharacters = Array(prefix)
        let maximumLength = min(prefixCharacters.count, 160)
        guard maximumLength >= 8 else { return nil }

        for length in stride(from: maximumLength, through: 8, by: -1) {
            let probe = String(prefixCharacters.suffix(length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard probe.count >= 8,
                  let range = output.range(
                    of: probe,
                    options: [.caseInsensitive, .diacriticInsensitive]
                  ) else { continue }
            let tail = String(output[range.upperBound...])
            guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return tail
        }
        return nil
    }

    private static func containsEarlierPrefixEcho(_ prefix: String, in output: String) -> Bool {
        let visible = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard visible.count >= 8 else { return false }

        // Catch short, complete copied fragments such as an email salutation. Requiring
        // more than one word avoids flagging ordinary single-word predictions.
        if visible.split(whereSeparator: \Character.isWhitespace).count >= 2,
           contains(visible, in: prefix) {
            return true
        }

        // Qwen can copy a sentence from anywhere in the captured prefix and then add
        // more text. Comparing the leading output fragment catches that behavior even
        // when the copied sentence is not adjacent to the caret.
        let head = Array(visible.prefix(40))
        guard head.count >= 12 else { return false }
        for length in stride(from: head.count, through: 12, by: -1) {
            let probe = String(head.prefix(length)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard probe.count >= 12 else { continue }
            if contains(probe, in: prefix) { return true }
        }
        return false
    }

    private static func containsSuffixEcho(_ suffix: String, in output: String) -> Bool {
        let head = Array(suffix.prefix(40))
        guard head.count >= 12 else { return false }
        for length in stride(from: head.count, through: 12, by: -1) {
            let probe = String(head.prefix(length)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard probe.count >= 12 else { continue }
            if contains(probe, in: output) { return true }
        }
        return false
    }

    private static func contains(_ probe: String, in output: String) -> Bool {
        output.range(of: probe, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }
}
