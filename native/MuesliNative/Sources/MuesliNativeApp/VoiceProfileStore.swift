import Darwin
import Foundation

/// This directory belongs to one installed app/lane and is never a sync/export root.
final class VoiceProfileStore {
    let profileURL: URL
    let enrollmentDirectory: URL
    private let directory: URL

    init(supportDirectory: URL) throws {
        directory = supportDirectory.appendingPathComponent("VoiceProfile", isDirectory: true)
        profileURL = directory.appendingPathComponent("owner.json")
        enrollmentDirectory = directory.appendingPathComponent("Enrollment", isDirectory: true)
        for folder in [directory, enrollmentDirectory] {
            if FileManager.default.fileExists(atPath: folder.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw OwnerVoiceProfileError.invalidProfile
                }
            } else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        try cleanEnrollmentArtifacts()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(".profile-") && url.pathExtension == "tmp" {
            try FileManager.default.removeItem(at: url)
        }
    }

    func load(modelIdentity: String) throws -> OwnerVoiceProfile? {
        guard let profile = try loadStored(), profile.modelIdentity == modelIdentity else { return nil }
        return profile
    }

    /// Schema validation only; inference must additionally compare the loaded model fingerprint.
    func loadStored() throws -> OwnerVoiceProfile? {
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: profileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
        let data = try Data(contentsOf: profileURL)
        guard let profile = try? JSONDecoder().decode(OwnerVoiceProfile.self, from: data),
              (try? profile.validate()) != nil else { return nil }
        let savedID = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if UUID(uuidString: savedID?["id"] as? String ?? "") == nil {
            // Older local files have no stable UUID. Persist it immediately so meeting
            // evidence keeps the same profile provenance across future launches.
            try replace(profile)
        }
        return profile
    }

    func replace(_ profile: OwnerVoiceProfile) throws {
        try profile.validate()
        let data = try JSONEncoder().encode(profile)
        let temporary = directory.appendingPathComponent(".profile-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var closed = false
        defer {
            if !closed { close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard close(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        closed = true
        guard rename(temporary.path, profileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func delete() throws {
        try cleanEnrollmentArtifacts()
        if FileManager.default.fileExists(atPath: profileURL.path) {
            try FileManager.default.removeItem(at: profileURL)
        }
    }

    func cleanEnrollmentArtifacts() throws {
        for url in try FileManager.default.contentsOfDirectory(at: enrollmentDirectory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
