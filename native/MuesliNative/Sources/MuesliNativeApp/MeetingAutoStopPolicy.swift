import Foundation

struct MeetingAutoStopSource: Equatable {
    let candidateID: String?
    let suppressionID: String?
    let normalizedURL: String?
    let sourceBundleID: String?

    private init(
        candidateID: String?,
        suppressionID: String?,
        normalizedURL: String?,
        sourceBundleID: String?
    ) {
        self.candidateID = candidateID
        self.suppressionID = suppressionID
        self.normalizedURL = normalizedURL
        self.sourceBundleID = sourceBundleID
    }

    init(candidate: MeetingCandidate) {
        self.candidateID = candidate.id
        self.suppressionID = candidate.suppressionID
        self.normalizedURL = candidate.url
        self.sourceBundleID = candidate.sourceBundleID
    }

    init?(meetingURL: URL) {
        guard let normalized = MeetingURLNormalizer.normalize(meetingURL.absoluteString) else {
            return nil
        }
        self.candidateID = normalized.id
        self.suppressionID = normalized.id
        self.normalizedURL = normalized.url
        self.sourceBundleID = nil
    }

    func refined(with candidate: MeetingCandidate) -> MeetingAutoStopSource {
        MeetingAutoStopSource(
            candidateID: candidateID ?? candidate.id,
            suppressionID: candidate.suppressionID,
            normalizedURL: normalizedURL ?? candidate.url,
            sourceBundleID: sourceBundleID ?? candidate.sourceBundleID
        )
    }
}

enum MeetingAutoStopPolicy {
    static func matches(candidate: MeetingCandidate, source: MeetingAutoStopSource) -> Bool {
        if let candidateID = source.candidateID, candidate.id == candidateID {
            return true
        }

        if let suppressionID = source.suppressionID, candidate.suppressionID == suppressionID {
            return true
        }

        if let normalizedURL = source.normalizedURL, candidate.url == normalizedURL {
            return true
        }

        if let sourceBundleID = source.sourceBundleID,
           candidate.sourceBundleID == sourceBundleID,
           candidate.evidence.contains(.audioInputProcess) {
            return true
        }

        return false
    }
}
