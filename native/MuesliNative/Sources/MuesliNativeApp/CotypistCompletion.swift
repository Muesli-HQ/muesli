import Foundation

enum CotypistModelOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwen35_0_8b = "qwen35_0_8b"
    case gemma4E2B = "gemma4_e2b"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .qwen35_0_8b: return "Qwen3.5 0.8B"
        case .gemma4E2B: return "Gemma 4 E2B"
        }
    }

    var detail: String {
        switch self {
        case .qwen35_0_8b: return "Fastest. Uses the existing vanilla GGUF language model."
        case .gemma4E2B: return "Higher quality, with a larger memory footprint."
        }
    }

    var isDownloaded: Bool {
        switch self {
        case .qwen35_0_8b: return PostProcessorOption.qwen35_0_8b.isDownloaded
        case .gemma4E2B: return Gemma4LiteRTModelStore.isAvailableLocally()
        }
    }

    static func resolved(_ rawValue: String?) -> CotypistModelOption {
        rawValue.flatMap(CotypistModelOption.init(rawValue:)) ?? .qwen35_0_8b
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
        if containsAny(identity + " " + location, ["slack", "discord", "teams", "messages", "messenger", "whatsapp", "telegram", "signal", "chat.openai", "claude.ai"]) {
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

struct CotypistCompletionRequest: Equatable, Sendable {
    static let maximumOutputTokens = 24
    static let systemPromptTemplate = """
    You are a macOS inline writing prediction engine. Return only the exact missing continuation at <CARET>; never explain, quote, label, or repeat context. Preserve the writer's language, tone, capitalization, formatting, and indentation. Make the continuation fit naturally before the suffix. Prefer one short phrase or sentence fragment. Stop as soon as the likely thought is complete.
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

    var systemPrompt: String {
        Self.systemPromptTemplate
    }

    var userPrompt: String {
        let metadata = [
            "Surface: \(surface.rawValue)",
            "App: \(context.appName)",
            context.browserLocation.map { "Location: \($0)" },
            context.fieldMetadata.isEmpty ? nil : "Field: \(context.fieldMetadata)",
        ].compactMap { $0 }.joined(separator: "\n")
        return """
        \(metadata)
        <PREFIX>\(context.prefix)</PREFIX><CARET><SUFFIX>\(context.suffix)</SUFFIX>
        Continue at <CARET>. Output continuation only.
        """
    }

    var gemmaUserPrompt: String {
        """
        Fill the cursor gap with a short natural continuation. Return only the missing text, including any required leading space. Never repeat BEFORE or AFTER.
        For example, when BEFORE is "Please send the report" and AFTER is " by Friday.", the missing text alone is " to me".

        Surface: \(surface.rawValue)
        BEFORE: \(context.prefix)
        AFTER: \(context.suffix)
        Supply only the missing continuation now, without a heading, label, quotation marks, or explanation.
        """
    }
}

enum CotypistOutputSanitizer {
    static func sanitize(_ raw: String, for context: FocusedTextContext) -> String? {
        guard !raw.isEmpty, raw.count <= 1_000 else { return nil }
        guard !raw.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar) && scalar.value != 10 && scalar.value != 9
        }) else { return nil }

        let lower = raw.lowercased()
        let structuralMarkers = [
            "<think", "</think", "<|im_", "```", "<prefix>", "</prefix>",
            "<suffix>", "</suffix>", "<caret>",
        ]
        guard !structuralMarkers.contains(where: lower.contains) else { return nil }

        let visible = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }
        let lowerVisible = visible.lowercased()
        let commentaryPrefixes = [
            "assistant:", "analysis:", "reasoning:", "completion:", "continuation:", "insert:",
            "here is", "i suggest", "the user", "as an ai",
        ]
        guard !commentaryPrefixes.contains(where: lowerVisible.hasPrefix) else { return nil }
        if (visible.hasPrefix("\"") && visible.hasSuffix("\""))
            || (visible.hasPrefix("'") && visible.hasSuffix("'")) {
            return nil
        }

        let prefixProbe = String(context.prefix.suffix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefixProbe.count >= 12 && visible.hasPrefix(prefixProbe) { return nil }
        let suffixProbe = String(context.suffix.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        if suffixProbe.count >= 12 && visible == suffixProbe { return nil }
        if !suffixProbe.isEmpty, visible.hasSuffix(suffixProbe), visible.count > suffixProbe.count {
            return nil
        }

        // A 24-token response should stay well below this character ceiling even for
        // code-heavy output; this catches runaway or echoed prompts without trimming
        // meaningful leading whitespace.
        guard raw.count <= 320 else { return nil }

        // LiteRT text responses can omit a required leading space even when the prompt
        // explicitly requests it. Preserve every byte the model returned and add only
        // the separator needed to prevent two natural-language words from being glued
        // together. Code and mid-token suffixes must remain byte-exact.
        if CotypistSurface.classify(context: context) != .code,
           let prefixLast = context.prefix.last,
           let outputFirst = raw.first,
           isWordCharacter(prefixLast),
           isWordCharacter(outputFirst),
           context.suffix.first.map(isWordCharacter) != true {
            return " " + raw
        }
        return raw
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }
}
