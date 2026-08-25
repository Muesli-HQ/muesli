import Darwin
import Foundation

/// Resolves a credential by running a user-configured shell command.
public enum CredentialCommandRunner {
    public static let defaultTimeout: TimeInterval = 10

    public static func resolve(
        command: String,
        fallback: String,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty, !trimmedCommand.contains("\0") else {
            return trimmedFallback
        }

        let processBox = CredentialCommandProcessBox()
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let output = try runSync(
                            command: trimmedCommand,
                            timeout: max(timeout, 0.1),
                            processBox: processBox
                        )
                        if processBox.clear() {
                            throw CancellationError()
                        }
                        continuation.resume(returning: output ?? trimmedFallback)
                    } catch {
                        _ = processBox.clear()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            processBox.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private static func runSync(
        command: String,
        timeout: TimeInterval,
        processBox: CredentialCommandProcessBox
    ) throws -> String? {
        let spawned: SpawnedCredentialProcess
        do {
            spawned = try spawn(command: command)
        } catch {
            fputs("[credential-command] failed to launch\n", stderr)
            return nil
        }

        guard processBox.set(spawned.processIdentifier) else {
            terminateProcessGroup(spawned.processIdentifier)
            spawned.stdout.stop()
            throw CancellationError()
        }

        let waitResult = waitForProcess(spawned.processIdentifier, timeout: timeout)
        if waitResult.timedOut {
            terminateProcessGroup(spawned.processIdentifier)
        }
        spawned.stdout.finishAfterProcessExit()

        if waitResult.timedOut {
            fputs("[credential-command] timed out after \(timeout)s\n", stderr)
            return nil
        }

        guard waitResult.exitCode == 0 else {
            if processBox.isCancelled {
                return nil
            }
            // Never log credential output or subprocess stderr content.
            fputs("[credential-command] exited with status \(waitResult.exitCode)\n", stderr)
            return nil
        }

        guard !spawned.stdout.wasTruncated else {
            fputs("[credential-command] stdout exceeded 8192 bytes\n", stderr)
            return nil
        }

        let output = spawned.stdout.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private static func spawn(command: String) throws -> SpawnedCredentialProcess {
        var stdoutDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutDescriptors) == 0 else {
            throw POSIXError(.EIO)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(stdoutDescriptors[0])
            close(stdoutDescriptors[1])
            throw POSIXError(.EIO)
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&fileActions)
            close(stdoutDescriptors[0])
            close(stdoutDescriptors[1])
            throw POSIXError(.EIO)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let actionStatuses = [
            posix_spawn_file_actions_adddup2(&fileActions, stdoutDescriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_addclose(&fileActions, stdoutDescriptors[0]),
            posix_spawn_file_actions_addclose(&fileActions, stdoutDescriptors[1]),
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDERR_FILENO,
                "/dev/null",
                O_WRONLY,
                mode_t(0)
            ),
        ]

        // A dedicated process group lets timeout and cancellation terminate the
        // shell and any descendants it launched.
        let attributeStatuses = [
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
        ]
        guard (actionStatuses + attributeStatuses).allSatisfy({ $0 == 0 }) else {
            close(stdoutDescriptors[0])
            close(stdoutDescriptors[1])
            throw POSIXError(.EIO)
        }

        var processIdentifier: pid_t = 0
        let arguments = ["/bin/sh", "-c", command]
        let environment = ProcessInfo.processInfo.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }

        let spawnStatus = withMutableCStringArray(arguments) { argumentPointers in
            withMutableCStringArray(environment) { environmentPointers in
                posix_spawn(
                    &processIdentifier,
                    "/bin/sh",
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }

        close(stdoutDescriptors[1])
        guard spawnStatus == 0 else {
            close(stdoutDescriptors[0])
            throw POSIXError(POSIXErrorCode(rawValue: spawnStatus) ?? .EIO)
        }

        return SpawnedCredentialProcess(
            processIdentifier: processIdentifier,
            stdout: BoundedPipeCollector(fileDescriptor: stdoutDescriptors[0], capacity: 8192)
        )
    }

    private static func waitForProcess(_ processIdentifier: pid_t, timeout: TimeInterval) -> WaitResult {
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0

        while Date() < deadline {
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier {
                return WaitResult(exitCode: exitCode(from: status), timedOut: false)
            }
            if result == -1 {
                return WaitResult(exitCode: -1, timedOut: false)
            }
            usleep(10_000)
        }

        return WaitResult(exitCode: -1, timedOut: true)
    }

    private static func terminateProcessGroup(_ processIdentifier: pid_t) {
        guard processIdentifier > 0 else { return }
        let processGroup = -processIdentifier
        kill(processGroup, SIGTERM)

        let graceDeadline = Date().addingTimeInterval(0.25)
        while Date() < graceDeadline {
            if kill(processGroup, 0) == -1, errno == ESRCH {
                break
            }
            usleep(10_000)
        }

        if kill(processGroup, 0) == 0 {
            kill(processGroup, SIGKILL)
        }

        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) == -1, errno == EINTR {}
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + signal
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

private struct SpawnedCredentialProcess {
    let processIdentifier: pid_t
    let stdout: BoundedPipeCollector
}

private struct WaitResult {
    let exitCode: Int32
    let timedOut: Bool
}

private final class BoundedPipeCollector: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let capacity: Int
    private let queue = DispatchQueue(label: "com.muesli.core.credential-output-buffer")
    private let eofSemaphore = DispatchSemaphore(value: 0)
    private var data = Data()
    private var byteCount = 0
    private var finished = false

    init(fileDescriptor: Int32, capacity: Int) {
        self.fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        self.capacity = max(capacity, 1)
        fileHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                finish()
            } else {
                append(chunk)
            }
        }
    }

    var wasTruncated: Bool {
        queue.sync { byteCount > capacity }
    }

    var stringValue: String {
        queue.sync { String(decoding: data, as: UTF8.self) }
    }

    func finishAfterProcessExit() {
        if eofSemaphore.wait(timeout: .now() + .seconds(1)) == .timedOut {
            stop()
        } else {
            try? fileHandle.close()
        }
    }

    func stop() {
        fileHandle.readabilityHandler = nil
        try? fileHandle.close()
        finish()
    }

    private func append(_ chunk: Data) {
        queue.sync {
            byteCount += chunk.count
            data.append(chunk)
            if data.count > capacity {
                data.removeFirst(data.count - capacity)
            }
        }
    }

    private func finish() {
        let shouldSignal = queue.sync { () -> Bool in
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldSignal {
            fileHandle.readabilityHandler = nil
            eofSemaphore.signal()
        }
    }
}

private final class CredentialCommandProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var processIdentifier: pid_t?
    private var cancelled = false

    func set(_ processIdentifier: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.processIdentifier = processIdentifier
        return true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let currentProcessIdentifier = processIdentifier
        lock.unlock()

        guard let currentProcessIdentifier else { return }
        let processGroup = -currentProcessIdentifier
        kill(processGroup, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            if kill(processGroup, 0) == 0 {
                kill(processGroup, SIGKILL)
            }
        }
    }

    @discardableResult
    func clear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasCancelled = cancelled
        processIdentifier = nil
        return wasCancelled
    }
}
