import Foundation
import Darwin

/// Preserves a failed streaming session for explicit recovery without rerunning
/// transcription or moving/deleting the recorder's original audio.
enum BufferedDictationRecovery {
    enum Failure: Error {
        case inputIsNotRegularFile
    }

    /// A small fallback when copying the WAV into the recovery directory fails.
    /// Reserve a private sidecar atomically; never overwrite an earlier attempt.
    static func saveTranscript(_ transcript: String, beside wavURL: URL) throws -> URL {
        let data = Data(transcript.utf8)
        let sidecar = wavURL.appendingPathExtension("transcript.txt")
        if try writeNew(data, to: sidecar) { return sidecar }
        let unique = wavURL.appendingPathExtension("\(UUID().uuidString).transcript.txt")
        guard try writeNew(data, to: unique) else { throw CocoaError(.fileWriteFileExists) }
        return unique
    }

    private static func writeNew(_ data: Data, to url: URL) throws -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                              S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return true
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func save(wavURL: URL, transcript: String, directory: URL) throws -> URL {
        let files = FileManager.default
        let attributes = try files.attributesOfItem(atPath: wavURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.inputIsNotRegularFile
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let session = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: session, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        do {
            let audio = session.appendingPathComponent("audio.wav")
            try files.copyItem(at: wavURL, to: audio)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
            let text = session.appendingPathComponent("transcript.txt")
            try Data(transcript.utf8).write(to: text, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: text.path)
            return session
        } catch {
            // Only this invocation's incomplete copy is disposable. The source
            // and every previously saved recovery remain available on failure.
            try? files.removeItem(at: session)
            throw error
        }
    }
}
