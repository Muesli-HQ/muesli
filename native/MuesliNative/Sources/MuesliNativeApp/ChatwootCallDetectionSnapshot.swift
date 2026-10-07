import Foundation

/// Read-only projection boundary. Providers must pin process launch, active window/tab,
/// document AND route generation before/after the read. UUIDs must be opaque and stable
/// for that scope; sessionID must rotate on every new/reconnected remote call.
/// No capture, click, messaging, identity persistence or consent capability is exposed.
protocol ChatwootCallDetectionSnapshotProviding: Sendable {
    func snapshot(deadline: ContinuousClock.Instant) async -> ChatwootCallDetectionSnapshotResult
}

enum ChatwootCallDetectionSnapshotResult: Sendable {
    case snapshot(ChatwootCallDetectionSnapshot)
    case unavailable(CallDetectionUnavailableReason)
}

struct ChatwootCallDetectionSnapshot: Sendable {
    let sourceBefore: CallDetectionSource
    let sourceAfter: CallDetectionSource
    let urlBefore: String
    let urlAfter: String
    let observedAt: Date
    let profile: ChatwootCallDetectionProfile
    let product: ChatwootCallDetectionProductProof
    let surfaces: [ChatwootCallDetectionSurface]
}

/// This revision describes compiled synthetic fixtures ONLY. No browser/Chatwoot
/// version is validated for production positives. A future reader needs its own review.
enum ChatwootCallDetectionProfile: Sendable, Equatable {
    case syntheticScopedV1, unverified
}

enum ChatwootCallDetectionProductProof: Sendable {
    case scopedChatwootProfile, configuredOrigin, unverified
}

struct ChatwootCallDetectionSurface: Sendable {
    let sessionID: UUID
    let kind: ChatwootCallDetectionSurfaceKind
    let phase: CallDetectionPhase
    let transport: ChatwootCallDetectionTransport
    let hasEndControl: Bool
    let hasMuteControl: Bool
    let roster: ChatwootCallDetectionRosterSnapshot
}

enum ChatwootCallDetectionSurfaceKind: Sendable, Equatable {
    case activeCall, voiceNote, history, deviceTest
}

enum ChatwootCallDetectionTransport: Sendable, Equatable {
    /// The remote party is connected; a local Twilio conference leg is insufficient.
    case remoteConnected, localOnly, disconnected, unknown
}

enum ChatwootCallDetectionRosterSnapshot: Sendable {
    case unknown
    case partial(Set<UUID>)
    /// Complete is allowed only when the scoped provider positively enumerated everyone.
    case complete(Set<UUID>)
}

enum ChatwootCallDetectionOrigin {
    /// Origin comparison includes scheme + host + effective port, never URL suffixes.
    /// Reject ambiguous host spellings instead of broadening an origin allowlist.
    static func canonical(_ raw: String) -> String? {
        guard raw.utf8.count <= 8192,
              !raw.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }), !raw.contains("\\"), validEscapes(raw),
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              !host.hasSuffix("."),
              host.unicodeScalars.allSatisfy({ $0.isASCII }),
              let separator = raw.range(of: "://") else { return nil }
        let authority = raw[separator.upperBound...].prefix { !"/?#".contains($0) }
        guard !authority.isEmpty, !authority.contains("%"), !authority.contains("@"),
              !authority.hasSuffix(":"),
              host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:[]".contains($0) }),
              unambiguousIPv4Spelling(host) else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        let normalizedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(normalizedHost):\(port)"
    }

    private static func unambiguousIPv4Spelling(_ host: String) -> Bool {
        // Browsers treat a numeric terminal label as an IPv4 candidate, including
        // hex, octal and shortened forms. Accept only four canonical decimal bytes.
        // Colon-bearing IPv6 and ordinary DNS hosts stay on their existing path.
        if host.contains(":") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard let last = labels.last, !last.isEmpty else { return false }
        let decimal = last.allSatisfy(\.isNumber)
        let hex = last.hasPrefix("0x") && last.dropFirst(2).allSatisfy {
            "0123456789abcdef".contains($0)
        }
        guard decimal || hex else { return true }
        return labels.count == 4 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy(\.isNumber)
                && (label.count == 1 || label.first != "0")
                && UInt8(label) != nil
        }
    }

    private static func validEscapes(_ raw: String) -> Bool {
        let bytes = Array(raw.utf8)
        var index = 0
        func hex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return false }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }
}
