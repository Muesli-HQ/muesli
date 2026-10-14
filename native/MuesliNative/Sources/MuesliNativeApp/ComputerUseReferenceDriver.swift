import AppKit
import Darwin

/// Local benchmark only. Launches the unmodified reference driver as a direct
/// child so macOS can attribute permission checks to the dev host.
@MainActor
final class ComputerUseReferenceDriver {
    static var selectedExecutable: String? {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.muesli.dev") == true,
              let index = CommandLine.arguments.firstIndex(of: "--trycua-driver"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
    private(set) var serverVersion = "unknown"
    private(set) var tools: [[String: Any]] = []
    private var daemon: Process?
    private var proxy: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var log: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var busy = false
    private var directory: URL?

    func start(executable: String) async throws {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.muesli.dev") == true,
              daemon == nil, FileManager.default.isExecutableFile(atPath: executable) else {
            throw failure("Reference driver requires a dev host and an executable path")
        }
        // macOS Unix sockets have a short sun_path limit; the per-user
        // temporary directory plus a UUID exceeds it on this host.
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("muesli-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        directory = root
        let socket = root.appendingPathComponent("driver.sock").path
        let logURL = root.appendingPathComponent("driver.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forWritingTo: logURL)
        var environment = ProcessInfo.processInfo.environment
        environment["CUA_DRIVER_EMBEDDED"] = "1"
        environment["CUA_DRIVER_HOST_BUNDLE_ID"] = Bundle.main.bundleIdentifier
        environment["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = "false"
        // Do not inherit an ambient approval bypass from the shell.
        environment["CUA_DRIVER_PERMISSION_MODE"] = "standard"
        environment.removeValue(forKey: "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS")
        do {
            let service = Process()
            service.executableURL = URL(fileURLWithPath: executable)
            service.arguments = ["serve", "--embedded", "--socket", socket]
            service.environment = environment
            service.standardOutput = log; service.standardError = log
            try service.run()
            daemon = service
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: socket) {
                guard service.isRunning, Date() < deadline else { throw failure("Reference daemon failed to become ready") }
                try await Task.sleep(for: .milliseconds(100))
            }
            let client = Process(), toDriver = Pipe(), fromDriver = Pipe()
            client.executableURL = URL(fileURLWithPath: executable)
            client.arguments = ["mcp", "--embedded", "--socket", socket]
            client.environment = environment
            client.standardInput = toDriver; client.standardOutput = fromDriver; client.standardError = log
            try client.run()
            proxy = client; input = toDriver.fileHandleForWriting; output = fromDriver.fileHandleForReading
            let fd = fromDriver.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw failure("Cannot configure MCP read pipe") }
            let initialized = try await request(method: "initialize", params: [
                "protocolVersion": "2024-11-05", "capabilities": [:],
                "clientInfo": ["name": "MuesliReferenceBenchmark", "version": "1"]])
            let initializationResult = initialized["result"] as? [String: Any]
            serverVersion = (initializationResult?["serverInfo"] as? [String: Any])?["version"] as? String ?? "unknown"
            try save(initialized, name: "initialize.json")
            try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            let catalog = try await request(method: "tools/list", params: [:])
            guard let result = catalog["result"] as? [String: Any],
                  let definitions = result["tools"] as? [[String: Any]], result["nextCursor"] == nil else {
                throw failure("Incomplete reference tool catalog")
            }
            tools = definitions
            try save(catalog, name: "tools.json")
            try save(try await call(name: "check_permissions", arguments: ["prompt": false]), name: "permissions.json")
            try save(["pid": service.processIdentifier, "socket": socket, "executable": executable,
                      "host": Bundle.main.bundleIdentifier ?? "", "permission_mode": "standard"], name: "endpoint.json")
            fputs("[muesli-reference] Ready; evidence: \(root.path)\n", stderr)
        } catch {
            try? save(["error": error.localizedDescription], name: "failure.json")
            await stop()
            throw error
        }
    }

    func call(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let started = Date()
        let result = try await request(method: "tools/call", params: ["name": name, "arguments": arguments])
        try save(["tool": name, "arguments": arguments, "response": result,
                  "duration_ms": Date().timeIntervalSince(started) * 1000], name: "call-\(nextID).json")
        return result
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard !busy else { throw failure("Concurrent reference requests are not supported") }
        busy = true
        defer { busy = false }
        nextID += 1
        let id = nextID
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try Task.checkCancellation()
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
                if message["id"] as? Int == id {
                    if let error = message["error"] { throw failure("MCP error: \(error)") }
                    return message
                }
            }
            guard let output, proxy?.isRunning == true, daemon?.isRunning == true else { throw failure("Reference process exited") }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 16 * 1024 * 1024 else { throw failure("MCP response exceeded 16 MiB") }
            } else if count == 0 { throw failure("Reference MCP pipe closed") }
            else if errno != EAGAIN && errno != EINTR { throw failure("MCP pipe read failed") }
            else { try await Task.sleep(for: .milliseconds(20)) }
        }
        throw failure("Reference request timed out")
    }

    private func send(_ value: [String: Any]) throws {
        guard let input else { throw failure("Reference MCP not connected") }
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func save(_ value: [String: Any], name: String) throws {
        guard let directory else { return }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func stop() async {
        try? input?.close(); input = nil
        let children = [proxy, daemon].compactMap { $0 }
        for child in children where child.isRunning { child.terminate() }
        for _ in 0..<20 where children.contains(where: { $0.isRunning }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
        try? output?.close(); output = nil
        try? log?.close(); log = nil
        proxy = nil; daemon = nil; buffer.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("endpoint.json")) }
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "MuesliReferenceDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
