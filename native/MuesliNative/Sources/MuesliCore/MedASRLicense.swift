import Foundation

/// A local, versioned acknowledgement shared by the app and CLI. It is separate
/// from downloaded weights so deleting a model does not silently revoke terms.
public struct MedASRLicense: Sendable {
    public static let shared = MedASRLicense()
    public static let version = "hai-def-2024-11-15-policy-2024-11-14-v1"
    public static let termsURL = URL(string: "https://developers.google.com/health-ai-developer-foundations/terms")!
    public static let policyURL = URL(string: "https://developers.google.com/health-ai-developer-foundations/prohibited-use-policy")!
    public let recordURL: URL

    public init(recordURL: URL = MuesliPaths.defaultSupportDirectoryURL()
        .appendingPathComponent("ModelLicenses/medasr.json")) {
        self.recordURL = recordURL
    }

    private struct Acceptance: Codable {
        let version: String
        let acceptedAt: Date
    }

    public var isAccepted: Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: recordURL),
              let acceptance = try? decoder.decode(Acceptance.self, from: data)
        else { return false }
        return acceptance.version == Self.version
    }

    public func requireAcceptance() throws {
        guard isAccepted else { throw MedASRLicenseError.acceptanceRequired }
    }

    /// Only explicit manual UI acceptance or the CLI's --accept action calls this.
    public func accept() throws {
        _ = try Self.agreementText() // Fail closed if the distributed copy is missing.
        let fm = FileManager.default
        try fm.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Acceptance(version: Self.version, acceptedAt: Date()))
        try data.write(to: recordURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
    }

    public static func agreementText() throws -> String {
        guard let licenseURL = Bundle.module.url(forResource: "LICENSE", withExtension: "txt", subdirectory: "MedASR"),
              let policyURL = Bundle.module.url(forResource: "PROHIBITED_USE_POLICY", withExtension: "txt", subdirectory: "MedASR")
        else { throw MedASRLicenseError.missingAgreement }
        let license = try String(contentsOf: licenseURL, encoding: .utf8)
        let policy = try String(contentsOf: policyURL, encoding: .utf8)
        return """
        MedASR model terms

        By accepting, you agree that your use and redistribution of MedASR are governed by Google's HAI-DEF Terms of Use below. Section 3.2 and the Prohibited Use Policy are incorporated as binding restrictions on your use and redistribution. muesli's MIT license does not replace these model terms. No Google endorsement is implied.

        \(license)

        HAI-DEF Prohibited Use Policy

        \(policy)
        """
    }
}

public enum MedASRLicenseError: LocalizedError, Sendable {
    case acceptanceRequired
    case missingAgreement

    public var errorDescription: String? {
        switch self {
        case .acceptanceRequired:
            "Review and accept MedASR's terms in Models, or run muesli-cli model-terms medasr, then repeat with --accept."
        case .missingAgreement:
            "MedASR's terms are missing from this installation. Reinstall muesli before using this model."
        }
    }
}
