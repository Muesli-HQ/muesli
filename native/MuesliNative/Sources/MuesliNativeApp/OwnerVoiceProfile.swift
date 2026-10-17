import Foundation

enum OwnerVoiceProfileError: Error { case invalidProfile, invalidReference }

struct OwnerVoiceProfile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let modelIdentity: String
    let createdAt: Date
    let references: [[Float]]
    let acceptedSpeechSeconds: Double

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, modelIdentity, createdAt, references, acceptedSpeechSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        modelIdentity = try values.decode(String.self, forKey: .modelIdentity)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        references = try values.decode([[Float]].self, forKey: .references)
        acceptedSpeechSeconds = try values.decode(Double.self, forKey: .acceptedSpeechSeconds)
    }

    init(modelIdentity: String, references: [[Float]], acceptedSpeechSeconds: Double) throws {
        self.schemaVersion = 1
        self.id = UUID()
        self.modelIdentity = modelIdentity
        self.createdAt = Date()
        self.references = try references.map(Self.normalized)
        self.acceptedSpeechSeconds = acceptedSpeechSeconds
        try validate()
    }

    func validate() throws {
        guard schemaVersion == 1, !modelIdentity.isEmpty, references.count >= 2,
              references.count <= 30, acceptedSpeechSeconds.isFinite,
              (20...60).contains(acceptedSpeechSeconds), createdAt.timeIntervalSince1970.isFinite else {
            throw OwnerVoiceProfileError.invalidProfile
        }
        for vector in references {
            let normalized = try Self.normalized(vector)
            guard zip(vector, normalized).allSatisfy({ abs($0 - $1) < 0.001 }) else {
                throw OwnerVoiceProfileError.invalidReference
            }
        }
    }

    static func normalized(_ vector: [Float]) throws -> [Float] {
        guard vector.count == 256, vector.allSatisfy({ $0.isFinite }) else {
            throw OwnerVoiceProfileError.invalidReference
        }
        let norm = sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { throw OwnerVoiceProfileError.invalidReference }
        return vector.map { Float(Double($0) / norm) }
    }

    static func similarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard let a = try? normalized(lhs), let b = try? normalized(rhs) else { return -1 }
        return zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    }
}

struct OwnerVoiceGeneration {
    private(set) var value: UInt64 = 0
    mutating func begin() -> UInt64 { value &+= 1; return value }
    mutating func invalidate() { value &+= 1 }
    func accepts(_ token: UInt64) -> Bool { token == value }
}
