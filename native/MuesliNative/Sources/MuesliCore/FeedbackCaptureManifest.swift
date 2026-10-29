import Foundation

public enum FeedbackCaptureState: String, Codable, Sendable {
    case recording, processing, ready, recovered, failed
}

public struct FeedbackCaptureFailure: Codable, Equatable, Sendable {
    public var stage: String
    public var message: String
    public init(stage: String, message: String) { self.stage = stage; self.message = message }
}

/// Geometry is frozen before preparation. No window title or typed content is retained.
public struct FeedbackCaptureTarget: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        public let x: Double, y: Double, width: Double, height: Double, scale: Double
        public init(x: Double, y: Double, width: Double, height: Double, scale: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height; self.scale = scale
        }
    }
    public let mode: String
    public let displayId: UInt32
    public let frame: Frame
    public let appName: String
    public init(displayId: UInt32, frame: Frame, appName: String) {
        mode = "display"; self.displayId = displayId; self.frame = frame; self.appName = appName
    }
}

public struct FeedbackCaptureManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let createdAtMs: Int64
    public var durationMs: Int64
    public var state: FeedbackCaptureState
    public let target: FeedbackCaptureTarget
    public var video: String?
    public var videoOffsetMs: Int64?
    public var audio: String?
    public var transcript: FeedbackCaptureTranscript?
    public var failures: [FeedbackCaptureFailure]
    /// Also journaled before Finish, so crash recovery preserves sample zero.
    public var microphoneStartFrame: Int64?
    public var videoStartFrame: Int64?

    public init(id: String, createdAtMs: Int64, target: FeedbackCaptureTarget) {
        version = 1; self.id = id; self.createdAtMs = createdAtMs; self.target = target
        durationMs = 0; state = .recording; failures = []
    }
    public static func milliseconds(frame: Int64, origin: Int64) -> Int64 {
        Int64((Double(frame - origin) / 16).rounded())
    }
    public mutating func alignClocks() {
        if let mic = microphoneStartFrame, let video = videoStartFrame {
            videoOffsetMs = Self.milliseconds(frame: video, origin: mic)
        }
    }
    enum CodingKeys: String, CodingKey {
        case version, id, createdAtMs, durationMs, state, target, video, videoOffsetMs, audio, failures
        case microphoneStartFrame, videoStartFrame, transcript
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported Scrawl capture version \(version)")
        }
        id = try c.decode(String.self, forKey: .id)
        createdAtMs = try c.decode(Int64.self, forKey: .createdAtMs)
        durationMs = try c.decode(Int64.self, forKey: .durationMs)
        state = try c.decode(FeedbackCaptureState.self, forKey: .state)
        target = try c.decode(FeedbackCaptureTarget.self, forKey: .target)
        video = try c.decodeIfPresent(String.self, forKey: .video)
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        // Transcript is derived metadata; corruption here must not hide retained media.
        transcript = try? c.decode(FeedbackCaptureTranscript.self, forKey: .transcript)
        videoOffsetMs = try c.decodeIfPresent(Int64.self, forKey: .videoOffsetMs)
        microphoneStartFrame = try c.decodeIfPresent(Int64.self, forKey: .microphoneStartFrame)
        videoStartFrame = try c.decodeIfPresent(Int64.self, forKey: .videoStartFrame)
        var decodedFailures: [FeedbackCaptureFailure] = []
        if var failureEntries = try? c.nestedUnkeyedContainer(forKey: .failures) {
            while !failureEntries.isAtEnd {
                guard let entry = try? failureEntries.superDecoder() else { break }
                if let failure = try? FeedbackCaptureFailure(from: entry) { decodedFailures.append(failure) }
            }
        }
        failures = decodedFailures
    }
}

public struct FeedbackCaptureRecord: Identifiable, Sendable {
    public let id: String
    public let createdAt: Double
    public let durationMs: Int64
    public let state: FeedbackCaptureState
    public let bundlePath: String
    public let title: String
}
