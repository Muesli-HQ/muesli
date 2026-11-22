import SwiftUI

struct SettingsSearchEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let pane: SettingsPane
    let section: String
    let keywords: [String]
}

enum SettingsSearchIndex {
    static let entries: [SettingsSearchEntry] = [
        // MARK: - General

        SettingsSearchEntry(
            id: "settings.general.launchAtLogin",
            title: "Launch at login",
            subtitle: "Start muesli automatically when you log in to your Mac.",
            pane: .general,
            section: "General",
            keywords: ["startup", "login item", "auto launch", "boot", "start"]
        ),
        SettingsSearchEntry(
            id: "settings.general.openDashboard",
            title: "Open dashboard on launch",
            subtitle: "Show the muesli window automatically when the app opens.",
            pane: .general,
            section: "General",
            keywords: ["window", "startup", "launch", "menu bar", "dashboard"]
        ),
        SettingsSearchEntry(
            id: "settings.general.icloudSync",
            title: "iCloud Sync",
            subtitle: "Sync dictations and meetings privately with iPhone or iPad. Audio stays on this Mac.",
            pane: .general,
            section: "iCloud Sync",
            keywords: ["icloud", "sync", "iphone", "ipad", "bridge", "qr", "pair", "device", "cloudkit", "reconnect", "reset sync", "privacy"]
        ),
        SettingsSearchEntry(
            id: "settings.permissions",
            title: "Permissions",
            subtitle: "Microphone, Accessibility, Input Monitoring, Screen Recording, System Audio, and Calendars.",
            pane: .general,
            section: "Permissions",
            keywords: ["permissions", "privacy", "microphone", "accessibility", "input monitoring", "screen recording", "system audio", "calendars", "restart", "grant", "access"]
        ),
        SettingsSearchEntry(
            id: "settings.general.localStorage",
            title: "Local storage",
            subtitle: "Disk space used by downloaded models, meeting audio, video, Vidshots, and database.",
            pane: .general,
            section: "Local storage",
            keywords: ["disk", "space", "storage", "models", "database", "cache", "size", "usage"]
        ),
        SettingsSearchEntry(
            id: "settings.general.data",
            title: "Clear history",
            subtitle: "Permanently remove saved dictations or meeting history and retained audio.",
            pane: .general,
            section: "Data",
            keywords: ["clear", "delete", "erase", "reset", "dictation history", "meeting history", "data", "remove"]
        ),

        // MARK: - Dictations

        SettingsSearchEntry(
            id: FeatureTourTarget.dictationProviderSetting.rawValue,
            title: "Speech recognition provider",
            subtitle: "Choose on-device transcription or hosted OpenAI or OpenRouter dictation.",
            pane: .dictation,
            section: "Speech Recognition",
            keywords: ["provider", "speech recognition", "openai", "openrouter", "local", "hosted", "api key", "stt"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.model",
            title: "Dictation model",
            subtitle: "Transcription model used for dictation, or automatic fallback for hosted providers.",
            pane: .dictation,
            section: "Speech Recognition",
            keywords: ["model", "fallback", "parakeet", "whisper", "bodhan", "cohere", "apple speech", "gemma", "qwen", "language", "stt"]
        ),
        SettingsSearchEntry(
            id: FeatureTourTarget.liveDictation.rawValue,
            title: "Watch text appear during hands-free mode",
            subtitle: "Preview live dictation as you speak; applies cleanup when you stop.",
            pane: .dictation,
            section: "Speech Recognition",
            keywords: ["live dictation", "streaming", "preview", "hands-free", "real-time", "buffered"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.microphone",
            title: "Dictation microphone",
            subtitle: "Select an input device or Automatic (uses Mac mic with AirPods).",
            pane: .dictation,
            section: "Transcription",
            keywords: ["microphone", "mic", "input device", "audio input", "airpods", "automatic"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.dictionarySuggestions",
            title: "Dictionary suggestions",
            subtitle: "Suggests words from your corrections via Accessibility after dictation.",
            pane: .dictation,
            section: "Transcription",
            keywords: ["dictionary", "vocabulary", "custom words", "corrections", "spelling", "accessibility"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.recordings",
            title: "Keep long dictation recordings",
            subtitle: "Save audio on this Mac for playback and retranscription in history.",
            pane: .dictation,
            section: "Recordings",
            keywords: ["recordings", "audio", "retention", "retain", "keep audio", "playback", "retranscribe", "threshold", "minutes"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.cleanup",
            title: "AI transcript cleanup",
            subtitle: "Refine dictated text with an on-device or cloud cleanup model.",
            pane: .dictation,
            section: "Dictation Cleanup",
            keywords: ["cleanup", "post-processing", "ai", "refine", "grammar", "punctuation", "clean up"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.cleanupPreset",
            title: "Cleanup preset & prompt",
            subtitle: "Choose or manage transcript cleanup prompt presets.",
            pane: .dictation,
            section: "Dictation Cleanup",
            keywords: ["prompt", "preset", "cleanup prompt", "system prompt", "instructions", "manage presets"]
        ),
        SettingsSearchEntry(
            id: FeatureTourTarget.cloudCleanupSetting.rawValue,
            title: "Cleanup source & model",
            subtitle: "Choose local GGUF or Gemma, or a cloud AI provider for dictation cleanup.",
            pane: .dictation,
            section: "Dictation Cleanup",
            keywords: ["cleanup source", "cleanup model", "cloud cleanup", "ollama", "lm studio", "anthropic", "openai", "chatgpt", "openrouter", "gemma", "custom llm", "thinking"]
        ),
        SettingsSearchEntry(
            id: FeatureTourTarget.appFormatting.rawValue,
            title: "App Formatting",
            subtitle: "Set writing style, capitalization, and punctuation templates per app.",
            pane: .dictation,
            section: "App Formatting",
            keywords: ["app formatting", "style", "capitalization", "lowercase", "period", "templates", "per-app"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.pasteShortcut",
            title: "Paste shortcut",
            subtitle: "Customize the keyboard shortcut used to paste dictated or rewritten text.",
            pane: .dictation,
            section: "Advanced",
            keywords: ["paste", "shortcut", "hotkey", "keyboard", "cmd+v", "keybinding", "layout"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.pauseMedia",
            title: "Pause media during dictation",
            subtitle: "Automatically pause music or video playback while dictating.",
            pane: .dictation,
            section: "Advanced",
            keywords: ["pause media", "music", "playback", "audio", "spotify", "apple music"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.muteAudio",
            title: "Mute system audio during dictation",
            subtitle: "Silence Mac audio output while recording dictation.",
            pane: .dictation,
            section: "Advanced",
            keywords: ["mute", "system audio", "silence", "sound", "volume"]
        ),
        SettingsSearchEntry(
            id: "settings.dictation.appContext",
            title: "App context & Screen OCR",
            subtitle: "Share nearby app text and frontmost-window OCR for dictation cleanup.",
            pane: .dictation,
            section: "Advanced",
            keywords: ["app context", "screen context", "ocr", "accessibility", "screen recording", "privacy"]
        ),

        // MARK: - Meetings

        SettingsSearchEntry(
            id: "settings.meetings.microphone",
            title: "Meeting microphone",
            subtitle: "Audio input device used for meetings. Changes apply immediately.",
            pane: .meetings,
            section: "Transcription",
            keywords: ["microphone", "mic", "input device", "audio", "meeting mic"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.hoverTranscript",
            title: "Show transcript on hover",
            subtitle: "Display live meeting transcript over the recording pill or notch.",
            pane: .meetings,
            section: "Transcription",
            keywords: ["hover", "pill", "notch", "live transcript", "overlay"]
        ),
        SettingsSearchEntry(
            id: FeatureTourTarget.liveCaptionsSetting.rawValue,
            title: "Live transcript model",
            subtitle: "Model used for real-time live captions during meetings.",
            pane: .meetings,
            section: "Transcription",
            keywords: ["live captions", "live transcript", "streaming", "real-time", "nemotron", "apple speech"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.inRoomSpeakers",
            title: "Identify in-room speakers",
            subtitle: "Diarize voices picked up by your microphone for in-person meetings.",
            pane: .meetings,
            section: "Transcription",
            keywords: ["in-room", "diarize", "diarization", "microphone", "speakers", "headphones", "in-person"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.finalTranscript",
            title: "Final transcript model & language",
            subtitle: "Model and language used for the final meeting transcript.",
            pane: .meetings,
            section: "Transcription",
            keywords: ["final transcript", "meeting model", "whisper", "parakeet", "bodhan", "cohere", "language"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.context",
            title: "Meeting context",
            subtitle: "Include nearby app text and window OCR context for meeting summaries.",
            pane: .meetings,
            section: "Meeting Context",
            keywords: ["meeting context", "screen context", "ocr", "screen recording", "accessibility"]
        ),
        SettingsSearchEntry(
            id: FeatureTourTarget.meetingSummaryProvider.rawValue,
            title: "Meeting summary backend",
            subtitle: "Choose ChatGPT, Claude, OpenAI, OpenRouter, Gemma, Ollama, LM Studio, or Custom LLM.",
            pane: .meetings,
            section: "Meeting Summaries",
            keywords: ["summary", "summaries", "ai", "chatgpt", "claude code", "anthropic", "openai", "openrouter", "gemma", "ollama", "lm studio", "custom llm", "endpoint", "api key", "thinking", "output token limit"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.notes",
            title: "Meeting notes & templates",
            subtitle: "Default summary template, automatic retries, and custom note templates.",
            pane: .meetings,
            section: "Meeting Notes",
            keywords: ["templates", "meeting notes", "default template", "retries", "manage templates", "summary"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.autoRecord",
            title: "Auto-record calendar meetings",
            subtitle: "Automatically start recording when a scheduled calendar meeting begins.",
            pane: .meetings,
            section: "Recording",
            keywords: ["auto-record", "auto record", "calendar", "recording", "automatic"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.autoStop",
            title: "Stop recording when a meeting ends",
            subtitle: "Automatically stop Zoom, Teams, Webex, or browser recordings when the call ends.",
            pane: .meetings,
            section: "Recording",
            keywords: ["auto-stop", "stop recording", "zoom", "teams", "webex", "meet", "browser", "end"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.recordingPolicy",
            title: "Save meeting recording & format",
            subtitle: "Choose whether to retain meeting audio recordings and M4A or WAV format.",
            pane: .meetings,
            section: "Recording",
            keywords: ["save recording", "audio", "recordings", "m4a", "wav", "lossless", "format", "policy"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.autoExport",
            title: "Auto-export meetings",
            subtitle: "Export notes and transcripts automatically as Markdown or PDF.",
            pane: .meetings,
            section: "Auto Export",
            keywords: ["export", "auto export", "markdown", "pdf", "folder", "notes"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.notifications",
            title: "Meeting notifications",
            subtitle: "Scheduled meeting reminders, default join action, auto-detected calls, and muted apps.",
            pane: .meetings,
            section: "Meeting Notifications",
            keywords: ["notifications", "reminders", "auto-detected", "join link", "mute apps", "calls"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.calendars",
            title: "Calendars",
            subtitle: "Calendar access, upcoming meetings window, meeting-link filter, and enabled calendars.",
            pane: .meetings,
            section: "Calendars",
            keywords: ["calendar", "calendars", "upcoming", "eventkit", "icloud", "google calendar", "meeting links", "accounts"]
        ),
        SettingsSearchEntry(
            id: "settings.meetings.postMeetingHook",
            title: "Post-meeting hook",
            subtitle: "Run a local executable script with JSON metadata after each completed meeting.",
            pane: .meetings,
            section: "Advanced",
            keywords: ["hook", "script", "automation", "webhook", "json", "timeout", "post-meeting"]
        ),

        // MARK: - Appearance

        SettingsSearchEntry(
            id: FeatureTourTarget.recordingIndicatorStyle.rawValue,
            title: "Recording indicator style",
            subtitle: "Choose Notch or Floating indicator style, idle visibility, and screen position.",
            pane: .appearance,
            section: "Recording indicator",
            keywords: ["recording indicator", "notch", "floating", "pill", "classic", "position", "idle", "hover", "hotkey", "shortcut"]
        ),
        SettingsSearchEntry(
            id: "settings.appearance.theme",
            title: "Theme",
            subtitle: "Switch between System, Light, Dark, and Ultra Dark appearance.",
            pane: .appearance,
            section: "Appearance",
            keywords: ["theme", "ultra dark", "dark mode", "light mode", "system", "black", "oled", "appearance"]
        ),
        SettingsSearchEntry(
            id: "settings.appearance.menuBarIcon",
            title: "Menu bar icon",
            subtitle: "Choose the icon shown in the macOS menu bar.",
            pane: .appearance,
            section: "Appearance",
            keywords: ["menu bar", "icon", "status bar", "tray"]
        ),
        SettingsSearchEntry(
            id: "settings.appearance.showHotkeyMenu",
            title: "Show hotkey in menu bar",
            subtitle: "Display the dictation shortcut next to the menu bar icon.",
            pane: .appearance,
            section: "Appearance",
            keywords: ["hotkey", "shortcut", "menu bar", "keybinding"]
        ),
        SettingsSearchEntry(
            id: "settings.appearance.accentColor",
            title: "Accent color",
            subtitle: "Customize the primary accent and switch tint across muesli.",
            pane: .appearance,
            section: "Appearance",
            keywords: ["accent", "color", "tint", "swatch", "blue", "theme"]
        ),
        SettingsSearchEntry(
            id: "settings.appearance.soundEffects",
            title: "Play sound effects",
            subtitle: "Play subtle chimes when starting or finishing dictation.",
            pane: .appearance,
            section: "Appearance",
            keywords: ["sound", "chime", "audio feedback", "effects", "mute"]
        ),
        SettingsSearchEntry(
            id: "settings.appearance.showNextMeeting",
            title: "Show next meeting in menu bar",
            subtitle: "Display your upcoming calendar meeting countdown in the menu bar.",
            pane: .appearance,
            section: "Appearance",
            keywords: ["next meeting", "menu bar", "countdown", "calendar", "upcoming"]
        ),

        // MARK: - Experimental

        SettingsSearchEntry(
            id: "settings.experimental.vidshot",
            title: "Vidshot",
            subtitle: "Record a window or screen region with microphone narration. Captures stay on this Mac.",
            pane: .experimental,
            section: "Vidshot",
            keywords: ["vidshot", "feedback capture", "screen recording", "video", "draw modifier", "narration", "privacy"]
        ),
        SettingsSearchEntry(
            id: "settings.experimental.timeTurner",
            title: "Time Turner",
            subtitle: "Searchable screen history snapshots stored locally, with retention limits and excluded apps.",
            pane: .experimental,
            section: "Time Turner",
            keywords: ["time turner", "visual memory", "screen history", "snapshots", "retention", "storage", "excluded apps", "displays", "inactivity", "privacy"]
        ),
        SettingsSearchEntry(
            id: "settings.experimental.computerUse",
            title: "Computer Use",
            subtitle: "Enable AI desktop planner, choose ChatGPT or on-device Gemma, and set execution timeout.",
            pane: .experimental,
            section: "Computer Use",
            keywords: ["computer use", "cua", "planner", "automation", "desktop", "voice settings", "timeout", "gemma", "chatgpt", "on-device"]
        ),
        SettingsSearchEntry(
            id: FeatureTourTarget.quillSettings.rawValue,
            title: "Quill",
            subtitle: "Rewrite selected text or generate at the cursor using local or hosted writing models.",
            pane: .experimental,
            section: "Quill",
            keywords: ["quill", "rewrite", "writing", "transform", "sounds", "writing model", "ollama", "lm studio", "custom llm"]
        ),
        SettingsSearchEntry(
            id: FeatureTourTarget.cotypistSettings.rawValue,
            title: "Cotypist",
            subtitle: "Local typeahead autocomplete suggestions as you type in any app, with quiet-app exclusions.",
            pane: .experimental,
            section: "Cotypist",
            keywords: ["cotypist", "typeahead", "autocomplete", "suggestions", "quiet apps", "input source", "complete words", "screen context"]
        ),
    ]

    static func search(_ query: String, in entries: [SettingsSearchEntry] = entries) -> [SettingsSearchEntry] {
        let normalizedQuery = normalize(query)
        let tokens = normalizedQuery
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return [] }

        let fullQuery = tokens.joined(separator: " ")

        var scored: [(entry: SettingsSearchEntry, tier: Int, subRank: Int, index: Int)] = []
        scored.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            guard let (tier, subRank) = score(entry: entry, tokens: tokens, fullQuery: fullQuery) else {
                continue
            }
            scored.append((entry, tier, subRank, index))
        }

        scored.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.subRank != rhs.subRank { return lhs.subRank < rhs.subRank }
            return lhs.index < rhs.index
        }

        return scored.map(\.entry)
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func score(
        entry: SettingsSearchEntry,
        tokens: [String],
        fullQuery: String
    ) -> (tier: Int, subRank: Int)? {
        let title = normalize(entry.title)
        let subtitle = normalize(entry.subtitle)
        let section = normalize(entry.section)
        let paneTitle = normalize(entry.pane.title)
        let keywords = entry.keywords.map(normalize)

        let matchesAllTokens = tokens.allSatisfy { token in
            title.contains(token)
                || section.contains(token)
                || paneTitle.contains(token)
                || subtitle.contains(token)
                || keywords.contains { $0.contains(token) }
        }
        guard matchesAllTokens else { return nil }

        // 0: Exact title match
        if title == fullQuery {
            return (0, 0)
        }

        // 1: Title prefix
        if title.hasPrefix(fullQuery) {
            return (1, 0)
        }

        // 2: Title word or substring
        let titleWords = words(in: title)
        if titleWords.contains(fullQuery) {
            return (2, 0)
        }
        if titleWords.contains(where: { $0.hasPrefix(fullQuery) }) {
            return (2, 1)
        }
        if title.contains(fullQuery) {
            return (2, 2)
        }
        if tokens.allSatisfy({ token in titleWords.contains(token) }) {
            return (2, 3)
        }
        if tokens.allSatisfy({ token in titleWords.contains { $0.hasPrefix(token) } }) {
            return (2, 4)
        }
        if tokens.allSatisfy({ title.contains($0) }) {
            return (2, 5)
        }

        // 3: Keyword exact or prefix
        let keywordWords = keywords.flatMap(words(in:))
        if keywords.contains(fullQuery) {
            return (3, 0)
        }
        if keywords.contains(where: { $0.hasPrefix(fullQuery) }) {
            return (3, 1)
        }
        if keywordWords.contains(where: { $0 == fullQuery || $0.hasPrefix(fullQuery) }) {
            return (3, 2)
        }
        if tokens.allSatisfy({ token in
            keywords.contains { $0 == token || $0.hasPrefix(token) }
                || keywordWords.contains { $0 == token || $0.hasPrefix(token) }
        }) {
            return (3, 3)
        }

        // 4: Keyword substring
        if keywords.contains(where: { $0.contains(fullQuery) }) {
            return (4, 0)
        }
        if tokens.allSatisfy({ token in keywords.contains { $0.contains(token) } }) {
            return (4, 1)
        }

        // 5: Section or pane
        if section == fullQuery || paneTitle == fullQuery {
            return (5, 0)
        }
        if section.hasPrefix(fullQuery) || paneTitle.hasPrefix(fullQuery) {
            return (5, 1)
        }
        if section.contains(fullQuery) || paneTitle.contains(fullQuery) {
            return (5, 2)
        }
        if tokens.allSatisfy({ token in
            section.contains(token) || paneTitle.contains(token)
        }) {
            return (5, 3)
        }
        if tokens.contains(where: { token in
            section.contains(token) || paneTitle.contains(token)
        }) {
            return (5, 4)
        }

        // 6: Subtitle
        if subtitle.contains(fullQuery) {
            return (6, 0)
        }
        return (6, 1)
    }
}

// MARK: - Search UI Components

struct SettingsSearchBar: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding
    let hasResults: Bool
    let onMoveHighlight: (Int) -> Void
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isFocused.wrappedValue ? MuesliTheme.accentText : MuesliTheme.textTertiary)
                .accessibilityHidden(true)

            TextField("Search settings…", text: $query)
                .textFieldStyle(.plain)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textPrimary)
                .focused(isFocused)
                .onSubmit {
                    onSubmit()
                }
                .onKeyPress(.upArrow) {
                    guard hasResults else { return .ignored }
                    onMoveHighlight(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard hasResults else { return .ignored }
                    onMoveHighlight(1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !query.isEmpty || isFocused.wrappedValue else { return .ignored }
                    onClear()
                    return .handled
                }
                .accessibilityIdentifier("settings.search.field")
                .accessibilityLabel("Search settings")

            if !query.isEmpty {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.muesli(.quiet, shape: .circle))
                .accessibilityLabel("Clear search")
                .help("Clear search (Esc)")
            } else if !isFocused.wrappedValue {
                Text("⌘F")
                    .font(MuesliTheme.metadata())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MuesliTheme.backgroundRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                            .allowsHitTesting(false)
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .frame(height: 32)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay {
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(
                    isFocused.wrappedValue ? MuesliTheme.accent.opacity(0.65) : MuesliTheme.surfaceBorder,
                    lineWidth: isFocused.wrappedValue ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
    }
}

struct SettingsSearchResultsView: View {
    let query: String
    let results: [SettingsSearchEntry]
    let highlightedIndex: Int
    let stacksControls: Bool
    let onSelect: (SettingsSearchEntry) -> Void
    let onClear: () -> Void

    var body: some View {
        if results.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                HStack(spacing: MuesliTheme.spacing8) {
                    Text("\(results.count) \(results.count == 1 ? "match" : "matches")")
                        .font(MuesliTheme.metadata())
                        .foregroundStyle(MuesliTheme.textTertiary)
                    Spacer(minLength: 0)
                    if !stacksControls {
                        Text("↑↓ navigate · ↵ jump · Esc clear")
                            .font(MuesliTheme.metadata())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                }
                .padding(.horizontal, 2)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                        let isHighlighted = index == highlightedIndex
                        resultRow(entry, isHighlighted: isHighlighted)
                            .id(Self.rowScrollID(for: entry))
                    }
                }
                .padding(MuesliTheme.spacing8)
                .background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                )
            }
        }
    }

    static func rowScrollID(for entry: SettingsSearchEntry) -> String {
        "settings.search.result.\(entry.id)"
    }

    private var emptyState: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)
                .accessibilityHidden(true)

            VStack(spacing: MuesliTheme.spacing4) {
                Text("No settings matching \u{201C}\(query)\u{201D}")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Try searching for microphone, theme, iCloud, calendar, or shortcuts.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button("Clear search", action: onClear)
                .font(MuesliTheme.captionMedium())
                .padding(.horizontal, 12)
                .frame(height: 28)
                .buttonStyle(.muesli(.secondary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MuesliTheme.spacing32)
        .padding(.horizontal, MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private func resultRow(_ entry: SettingsSearchEntry, isHighlighted: Bool) -> some View {
        Button {
            onSelect(entry)
        } label: {
            let layout = stacksControls
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: MuesliTheme.spacing8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: MuesliTheme.spacing12))

            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.subtitle)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: MuesliTheme.spacing8) {
                    Text("\(entry.pane.title) · \(entry.section)")
                        .font(MuesliTheme.metadata())
                        .foregroundStyle(isHighlighted ? MuesliTheme.accentText : MuesliTheme.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isHighlighted ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isHighlighted ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder,
                                    lineWidth: 1
                                )
                                .allowsHitTesting(false)
                        )

                    if stacksControls {
                        Spacer(minLength: 0)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHighlighted ? MuesliTheme.accentText : MuesliTheme.textTertiary)
                        .accessibilityHidden(true)
                }
                .fixedSize(horizontal: !stacksControls, vertical: false)
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, MuesliTheme.spacing8)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .fill(MuesliTheme.accentSubtle)
                }
            }
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.accent.opacity(0.35), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.muesli(.quiet, compresses: false))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

private struct SettingsSearchAnchorModifier: ViewModifier {
    let anchorID: String
    let highlightedID: String?
    let isSection: Bool

    private var isHighlighted: Bool {
        highlightedID == anchorID
    }

    private var cornerRadius: CGFloat {
        isSection ? MuesliTheme.cornerMedium : MuesliTheme.cornerSmall
    }

    private var horizontalInset: CGFloat {
        isSection ? -2 : -6
    }

    private var verticalInset: CGFloat {
        isSection ? -2 : -2
    }

    func body(content: Content) -> some View {
        content
            .id(anchorID)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(MuesliTheme.accentSubtle)
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, verticalInset)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(MuesliTheme.accent.opacity(0.65), lineWidth: 1.5)
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, verticalInset)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func settingsSearchAnchor(
        _ id: String,
        highlightedID: String?,
        isSection: Bool = false
    ) -> some View {
        modifier(SettingsSearchAnchorModifier(
            anchorID: id,
            highlightedID: highlightedID,
            isSection: isSection
        ))
    }
}
