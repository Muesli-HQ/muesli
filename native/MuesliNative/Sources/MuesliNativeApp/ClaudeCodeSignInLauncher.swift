import AppKit
import MuesliCore

enum ClaudeCodeSignInLauncher {
    enum LaunchError: LocalizedError {
        case unavailable
        case couldNotOpenTerminal

        var errorDescription: String? {
            switch self {
            case .unavailable: "Claude Code is no longer available on this Mac."
            case .couldNotOpenTerminal: "Could not open Terminal for Claude Code sign-in."
            }
        }
    }

    @MainActor
    static func start(executablePath: String) throws {
        guard let executable = ClaudeCodeSummarizer.executableURL(configuredPath: executablePath) else {
            throw LaunchError.unavailable
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-claude-sign-in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let scriptURL = directory.appendingPathComponent("Sign in to Claude Code.command")
        do {
            let command = shellQuoted(executable.path)
            let script = "#!/bin/sh\ntrap 'rm -f \"$0\"; rmdir \"$(dirname \"$0\")\" 2>/dev/null' EXIT\n\(command) auth login\n"
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            guard NSWorkspace.shared.open(scriptURL) else { throw LaunchError.couldNotOpenTerminal }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
