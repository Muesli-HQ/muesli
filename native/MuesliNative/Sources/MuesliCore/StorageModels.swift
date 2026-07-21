import Foundation

public enum MeetingNotesState: String, Codable, Sendable {
    case missing
    case rawTranscriptFallback = "raw_transcript_fallback"
    case structuredNotes = "structured_notes"
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording
    case processing
    case completed
    case noteOnly = "note_only"
    case failed
}

public enum MeetingTemplateKind: String, Codable, Sendable {
    case auto
    case builtin
    case custom
}

public enum MeetingRecordingSavePolicy: String, Codable, CaseIterable, Sendable {
    case never
    case prompt
    case always
}

public enum MeetingSource: String, Codable, Sendable {
    case meeting
    case iOS = "ios"
    case audioImport = "audio_import"
}

public enum RecordOriginFilter: String, Codable, CaseIterable, Hashable, Sendable {
    case all
    case thisMac
    case fromIPhone
}

public enum SyncTextRecordKind: String, Codable, Sendable {
    case dictation
    case meeting
}

/// One target's publication state within `publish_state_json`: the remote id (`id`) the
/// record was pushed to, and the synced clock (`s`, same units as `updated_at`).
public struct PublishRef: Codable, Sendable, Equatable {
    public var id: String?
    public var syncedAt: Double?

    public init(id: String? = nil, syncedAt: Double? = nil) {
        self.id = id
        self.syncedAt = syncedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case syncedAt = "s"
    }

    /// Tolerant decode: the page id (`id`) must survive even if `s` (syncedAt) arrives in a
    /// slightly different shape from another device/version — e.g. a string instead of a number.
    /// A throwing decode here would null the whole ref and create a duplicate remote page, so we
    /// accept `s` as a Double or a numeric String and fall back to nil rather than failing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try? c.decodeIfPresent(String.self, forKey: .id)
        if let d = try? c.decodeIfPresent(Double.self, forKey: .syncedAt) {
            self.syncedAt = d
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .syncedAt) {
            self.syncedAt = Double(s)
        } else {
            self.syncedAt = nil
        }
    }

    /// Decodes a `publish_state_json` string (nil/empty/invalid → `[:]`) into a per-target map.
    /// Shared by `DictationStore` (the write path) and `SyncTextRecord.publishState()` (the read
    /// path) so the two never drift.
    public static func decodeMap(_ json: String?) -> [String: PublishRef] {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: PublishRef].self, from: data)) ?? [:]
    }

    /// Encodes a per-target map back to a compact `publish_state_json` string (`"{}"` on failure).
    public static func encodeMap(_ map: [String: PublishRef]) -> String {
        guard let data = try? JSONEncoder().encode(map), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

public struct SyncTextRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let kind: SyncTextRecordKind
    public var title: String?
    public var text: String
    public var speakerTranscript: String?
    public var summaryText: String?
    public var manualNotes: String?
    /// Per-target publication state as a raw JSON object keyed by target name
    /// (`{"notion":{"id":...,"s":...}}`), mirrored cross-device so a second machine
    /// updates the same remote page instead of creating a duplicate. Nil until pushed.
    public var publishStateJSON: String?
    public var source: String?
    /// Platform origin for UI badges lives in `source`; this preserves the
    /// local capture subtype such as dictation, cua, meeting, or audio_import.
    public var localSource: String?
    public var meetingStatus: MeetingStatus?
    public var engineIdentifier: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationSeconds: Double
    public var wordCount: Int
    public var isDeleted: Bool
    public var cloudChangeTag: String?
    public var followUpToRecordName: String?

    public init(
        id: String,
        kind: SyncTextRecordKind,
        title: String? = nil,
        text: String,
        speakerTranscript: String? = nil,
        summaryText: String? = nil,
        manualNotes: String? = nil,
        publishStateJSON: String? = nil,
        source: String? = nil,
        localSource: String? = nil,
        meetingStatus: MeetingStatus? = nil,
        engineIdentifier: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationSeconds: Double,
        wordCount: Int,
        isDeleted: Bool = false,
        cloudChangeTag: String? = nil,
        followUpToRecordName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.speakerTranscript = speakerTranscript
        self.summaryText = summaryText
        self.manualNotes = manualNotes
        self.publishStateJSON = publishStateJSON
        self.source = source
        self.localSource = localSource
        self.meetingStatus = meetingStatus
        self.engineIdentifier = engineIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.isDeleted = isDeleted
        self.cloudChangeTag = cloudChangeTag
        self.followUpToRecordName = followUpToRecordName
    }

    /// Returns a copy with `publishStateJSON` set (keeps all other fields).
    public func withPublishStateJSON(_ json: String?) -> SyncTextRecord {
        var copy = self
        copy.publishStateJSON = json
        return copy
    }

    /// Decodes `publishStateJSON` into a per-target map (empty when nil/invalid).
    public func publishState() -> [String: PublishRef] {
        PublishRef.decodeMap(publishStateJSON)
    }
}

/// A flattened one-way export payload for a single meeting or dictation, target-neutral.
/// Built by `DictationStore.*NeedingExport(target:)`. A record needs an export when the
/// target's synced clock (`s`) is null or older than `updated_at` (the write-clock every
/// mutation already bumps), so no separate dirty-flag plumbing is required.
public struct ExportRecord: Sendable, Equatable {
    public let kind: SyncTextRecordKind
    public let localID: Int64
    public let updatedAt: Double
    /// The current remote id for the target being exported, populated by the store query.
    public let existingRemoteID: String?
    public let title: String
    public let notesMarkdown: String?
    public let manualNotes: String?
    public let transcript: String?
    public let startTime: String?
    public let appContext: String?
    /// The meeting's template/kind (Interview, 1:1, …) for the target's "Meeting type"
    /// property. Nil for dictations.
    public let meetingType: String?

    public init(
        kind: SyncTextRecordKind, localID: Int64, updatedAt: Double, existingRemoteID: String?,
        title: String, notesMarkdown: String?, manualNotes: String?, transcript: String?,
        startTime: String?, appContext: String?, meetingType: String? = nil
    ) {
        self.kind = kind
        self.localID = localID
        self.updatedAt = updatedAt
        self.existingRemoteID = existingRemoteID
        self.title = title
        self.notesMarkdown = notesMarkdown
        self.manualNotes = manualNotes
        self.transcript = transcript
        self.startTime = startTime
        self.appContext = appContext
        self.meetingType = meetingType
    }
}

/// A record whose Notion (or other target) page should be archived because the local row was
/// soft-deleted. Built by `DictationStore.recordsNeedingUnpublish(target:)`: the row has a
/// `deleted_at` but still carries the target's remote page id in `publish_state_json`.
public struct UnpublishTarget: Sendable, Equatable {
    public let kind: SyncTextRecordKind
    public let localID: Int64
    public let remoteID: String

    public init(kind: SyncTextRecordKind, localID: Int64, remoteID: String) {
        self.kind = kind
        self.localID = localID
        self.remoteID = remoteID
    }
}

public struct LiveTranscriptCheckpointEntry: Sendable, Equatable {
    public let timestampLabel: String
    public let speaker: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(
        timestampLabel: String,
        speaker: String,
        startSeconds: Double,
        endSeconds: Double,
        text: String
    ) {
        self.timestampLabel = timestampLabel
        self.speaker = speaker
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

public struct DictationRecord: Identifiable, Codable, Sendable {
    public let id: Int64
    public let timestamp: String
    public let durationSeconds: Double
    public let rawText: String
    public let appContext: String
    public let wordCount: Int
    public let source: String
    public let computerUseTrace: ComputerUseTraceRecord?

    public init(
        id: Int64,
        timestamp: String,
        durationSeconds: Double,
        rawText: String,
        appContext: String,
        wordCount: Int,
        source: String = "dictation",
        computerUseTrace: ComputerUseTraceRecord? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.appContext = appContext
        self.wordCount = wordCount
        self.source = source
        self.computerUseTrace = computerUseTrace
    }
}

public struct ComputerUseTraceRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let dictationID: Int64
    public let finalStatus: String
    public let finalMessage: String
    public let events: [ComputerUseTraceEvent]
    public let createdAt: String

    public init(
        id: Int64,
        dictationID: Int64,
        finalStatus: String,
        finalMessage: String,
        events: [ComputerUseTraceEvent],
        createdAt: String
    ) {
        self.id = id
        self.dictationID = dictationID
        self.finalStatus = finalStatus
        self.finalMessage = finalMessage
        self.events = events
        self.createdAt = createdAt
    }
}

public struct ComputerUseTraceEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: String
    public let title: String
    public let body: String
    public let status: String?
    public let step: Int?
    public let timestamp: String

    public init(
        id: UUID = UUID(),
        kind: String,
        title: String,
        body: String,
        status: String? = nil,
        step: Int? = nil,
        timestamp: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.status = status
        self.step = step
        self.timestamp = timestamp
    }
}

public struct MeetingRecord: Identifiable, Codable, Sendable {
    public let id: Int64
    public let title: String
    public let startTime: String
    public let durationSeconds: Double
    public let rawTranscript: String
    public let formattedNotes: String
    public let wordCount: Int
    public let folderID: Int64?
    public let calendarEventID: String?
    public let micAudioPath: String?
    public let systemAudioPath: String?
    public let savedRecordingPath: String?
    public let status: MeetingStatus
    public let manualNotes: String
    public let selectedTemplateID: String?
    public let selectedTemplateName: String?
    public let selectedTemplateKind: MeetingTemplateKind?
    public let selectedTemplatePrompt: String?
    public let source: MeetingSource
    /// Self-referencing link: the meeting this one is a follow-up to. A meeting
    /// can have multiple follow-ups; root meetings have nil.
    public let followUpToID: Int64?
    /// Stable sync identity for the predecessor. Local row ids differ across
    /// devices, so sync uses the predecessor's cloud record name.
    public let followUpToRecordName: String?

    public init(
        id: Int64,
        title: String,
        startTime: String,
        durationSeconds: Double,
        rawTranscript: String,
        formattedNotes: String,
        wordCount: Int,
        folderID: Int64?,
        calendarEventID: String? = nil,
        micAudioPath: String? = nil,
        systemAudioPath: String? = nil,
        savedRecordingPath: String? = nil,
        status: MeetingStatus = .completed,
        manualNotes: String = "",
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil,
        source: MeetingSource = .meeting,
        followUpToID: Int64? = nil,
        followUpToRecordName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.rawTranscript = rawTranscript
        self.formattedNotes = formattedNotes
        self.wordCount = wordCount
        self.folderID = folderID
        self.calendarEventID = calendarEventID
        self.micAudioPath = micAudioPath
        self.systemAudioPath = systemAudioPath
        self.savedRecordingPath = savedRecordingPath
        self.status = status
        self.manualNotes = manualNotes
        self.selectedTemplateID = selectedTemplateID
        self.selectedTemplateName = selectedTemplateName
        self.selectedTemplateKind = selectedTemplateKind
        self.selectedTemplatePrompt = selectedTemplatePrompt
        self.source = source
        self.followUpToID = followUpToID
        self.followUpToRecordName = followUpToRecordName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case startTime
        case durationSeconds
        case rawTranscript
        case formattedNotes
        case wordCount
        case folderID
        case calendarEventID
        case micAudioPath
        case systemAudioPath
        case savedRecordingPath
        case status
        case manualNotes
        case selectedTemplateID
        case selectedTemplateName
        case selectedTemplateKind
        case selectedTemplatePrompt
        case source
        case followUpToID
        case followUpToRecordName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(Int64.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            startTime: try c.decode(String.self, forKey: .startTime),
            durationSeconds: try c.decode(Double.self, forKey: .durationSeconds),
            rawTranscript: try c.decode(String.self, forKey: .rawTranscript),
            formattedNotes: try c.decode(String.self, forKey: .formattedNotes),
            wordCount: try c.decode(Int.self, forKey: .wordCount),
            folderID: try c.decodeIfPresent(Int64.self, forKey: .folderID),
            calendarEventID: try c.decodeIfPresent(String.self, forKey: .calendarEventID),
            micAudioPath: try c.decodeIfPresent(String.self, forKey: .micAudioPath),
            systemAudioPath: try c.decodeIfPresent(String.self, forKey: .systemAudioPath),
            savedRecordingPath: try c.decodeIfPresent(String.self, forKey: .savedRecordingPath),
            status: (try? c.decode(MeetingStatus.self, forKey: .status)) ?? .completed,
            manualNotes: (try? c.decode(String.self, forKey: .manualNotes)) ?? "",
            selectedTemplateID: try c.decodeIfPresent(String.self, forKey: .selectedTemplateID),
            selectedTemplateName: try c.decodeIfPresent(String.self, forKey: .selectedTemplateName),
            selectedTemplateKind: try c.decodeIfPresent(MeetingTemplateKind.self, forKey: .selectedTemplateKind),
            selectedTemplatePrompt: try c.decodeIfPresent(String.self, forKey: .selectedTemplatePrompt),
            source: (try? c.decode(MeetingSource.self, forKey: .source)) ?? .meeting,
            followUpToID: try c.decodeIfPresent(Int64.self, forKey: .followUpToID),
            followUpToRecordName: try c.decodeIfPresent(String.self, forKey: .followUpToRecordName)
        )
    }

    public var notesState: MeetingNotesState {
        let trimmed = formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing }
        let normalized = trimmed.lowercased()
        if normalized == "## raw transcript" || normalized.hasPrefix("## raw transcript\n") {
            return .rawTranscriptFallback
        }
        return .structuredNotes
    }

    public var appliedTemplateID: String {
        let trimmed = selectedTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "auto" : trimmed
    }

    public var appliedTemplateName: String {
        let trimmed = selectedTemplateName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Auto" : trimmed
    }

    public var appliedTemplateKind: MeetingTemplateKind {
        selectedTemplateKind ?? .auto
    }
}

public struct MeetingFolder: Identifiable, Codable, Sendable {
    public let id: Int64
    public var name: String
    public let parentID: Int64?
    public let createdAt: String

    public init(id: Int64, name: String, parentID: Int64? = nil, createdAt: String) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

public struct DictationStats: Codable, Sendable {
    public let totalWords: Int
    public let totalSessions: Int
    public let averageWordsPerSession: Double
    public let averageWPM: Double
    public let currentStreakDays: Int
    public let longestStreakDays: Int

    public init(totalWords: Int, totalSessions: Int, averageWordsPerSession: Double, averageWPM: Double, currentStreakDays: Int, longestStreakDays: Int) {
        self.totalWords = totalWords
        self.totalSessions = totalSessions
        self.averageWordsPerSession = averageWordsPerSession
        self.averageWPM = averageWPM
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }
}

public struct MeetingStats: Codable, Sendable {
    public let totalWords: Int
    public let totalMeetings: Int
    public let averageWPM: Double

    public init(totalWords: Int, totalMeetings: Int, averageWPM: Double) {
        self.totalWords = totalWords
        self.totalMeetings = totalMeetings
        self.averageWPM = averageWPM
    }
}

public enum InsightsRange: String, CaseIterable, Codable, Sendable {
    case thirtyDays
    case ninetyDays
    case twelveMonths
    case allTime

    public func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: today)
        case .ninetyDays:
            return calendar.date(byAdding: .day, value: -89, to: today)
        case .twelveMonths:
            return calendar.date(byAdding: .year, value: -1, to: today)
        case .allTime:
            return nil
        }
    }
}

public struct InsightsTotals: Codable, Sendable, Equatable {
    public let dictationWords: Int
    public let dictationSessions: Int
    public let meetingWords: Int
    public let meetings: Int
    public let averageWPM: Double

    public var totalWords: Int { dictationWords + meetingWords }

    public init(dictationWords: Int, dictationSessions: Int, meetingWords: Int, meetings: Int, averageWPM: Double) {
        self.dictationWords = dictationWords
        self.dictationSessions = dictationSessions
        self.meetingWords = meetingWords
        self.meetings = meetings
        self.averageWPM = averageWPM
    }
}

public struct InsightsDailyActivity: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let words: Int
    public let meetings: Int

    public init(date: Date, words: Int, meetings: Int) {
        self.date = date
        self.words = words
        self.meetings = meetings
    }
}

public struct InsightsWordFrequency: Codable, Sendable, Equatable, Identifiable {
    public var id: String { word }
    public let word: String
    public let count: Int

    public init(word: String, count: Int) {
        self.word = word
        self.count = count
    }
}

public struct InsightsSnapshot: Codable, Sendable, Equatable {
    public let range: InsightsRange
    public let generatedAt: Date
    public let lifetime: InsightsTotals
    public let selected: InsightsTotals
    public let dailyActivity: [InsightsDailyActivity]
    public let currentStreakDays: Int
    public let longestStreakDays: Int
    public let activeDaysInRange: Int
    public let dictationWords: [InsightsWordFrequency]
    public let meetingWords: [InsightsWordFrequency]

    public init(
        range: InsightsRange,
        generatedAt: Date,
        lifetime: InsightsTotals,
        selected: InsightsTotals,
        dailyActivity: [InsightsDailyActivity],
        currentStreakDays: Int,
        longestStreakDays: Int,
        activeDaysInRange: Int,
        dictationWords: [InsightsWordFrequency],
        meetingWords: [InsightsWordFrequency]
    ) {
        self.range = range
        self.generatedAt = generatedAt
        self.lifetime = lifetime
        self.selected = selected
        self.dailyActivity = dailyActivity
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.activeDaysInRange = activeDaysInRange
        self.dictationWords = dictationWords
        self.meetingWords = meetingWords
    }
}
