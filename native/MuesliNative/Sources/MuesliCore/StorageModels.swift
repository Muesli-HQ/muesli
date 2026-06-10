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
    case audioImport = "audio_import"
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
        source: MeetingSource = .meeting
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
            source: (try? c.decode(MeetingSource.self, forKey: .source)) ?? .meeting
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
    public let createdAt: String

    public init(id: Int64, name: String, createdAt: String) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// Confidence tier for a diarized cluster's link to a saved voice profile.
public enum SpeakerMatchState: String, Codable, Sendable {
    /// No profile matched (renders as the raw `Speaker N`).
    case unmatched
    /// Borderline match surfaced as a suggestion for the user to confirm or reject.
    case suggested
    /// Confident automatic match (display name shown with an "auto-recognized" hint).
    case auto
    /// User explicitly named/confirmed this speaker.
    case confirmed
}

/// A persistent, cross-meeting voice profile (the Speakers library).
///
/// `embedding` is the representative 256-D voiceprint used for recognition;
/// `rawEmbeddings` retains the per-confirmation samples so the centroid can be
/// recomputed recoverably (re-average) rather than via a lossy in-place EMA.
public struct SpeakerProfile: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var embedding: [Float]
    public var rawEmbeddings: [[Float]]
    public var observationCount: Int
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        name: String,
        embedding: [Float],
        rawEmbeddings: [[Float]] = [],
        observationCount: Int = 1,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.rawEmbeddings = rawEmbeddings
        self.observationCount = observationCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Links one diarized cluster of a single meeting to a `Speaker N` label, its
/// representative embedding captured at stop, and its resolved name/profile.
public struct MeetingSpeaker: Identifiable, Codable, Sendable, Equatable {
    public let id: Int64
    public let meetingID: Int64
    public let speakerLabel: String
    public var embedding: [Float]
    public var profileID: String?
    public var displayName: String?
    public var matchDistance: Double?
    public var matchState: SpeakerMatchState

    public init(
        id: Int64,
        meetingID: Int64,
        speakerLabel: String,
        embedding: [Float],
        profileID: String? = nil,
        displayName: String? = nil,
        matchDistance: Double? = nil,
        matchState: SpeakerMatchState = .unmatched
    ) {
        self.id = id
        self.meetingID = meetingID
        self.speakerLabel = speakerLabel
        self.embedding = embedding
        self.profileID = profileID
        self.displayName = displayName
        self.matchDistance = matchDistance
        self.matchState = matchState
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
