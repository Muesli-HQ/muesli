import AppKit
import Darwin
import Combine

/// Local benchmark only. Launches the selected reference driver as a direct
/// child so macOS can attribute permission checks to the dev host.
@MainActor
final class ComputerUseReferenceDriver: ObservableObject {
    static let shared = ComputerUseReferenceDriver()
    enum ChromeAccessState: String {
        case notConnected = "Not connected"
        case connecting = "Awaiting Chrome approval"
        case connected = "Connected"
        case reconnectRequired = "Reconnect required"
    }
    @Published private(set) var chromeAccess: ChromeAccessState = .notConnected
    @Published private(set) var chromeAccessMessage: String?
    @Published private(set) var commandActive = false
    private var manualProfileAuthorization = false
    private var chromeSession: String?
    private var chromePID: Int32?
    private var connectedAt: Date?
    private var lastBrowserUse: Date?
    private var chromeEvents: DispatchSourceFileSystemObject?
    private var chromeEventURL: URL?
    private var chromeEventOffset: UInt64 = 0
    private var chromeEventBuffer = Data()
    private var chromeExpiryTask: Task<Void, Never>?

    static func isChromeDisconnectEvent(_ event: [String: Any], session: String?) -> Bool {
        guard let session else { return false }
        return event["session"] as? String == session && event["connected"] as? Bool == false
    }

    private func observeChromeEvents(at url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { throw failure("Cannot observe Chrome connection events") }
        chromeEventURL = url; chromeEventOffset = 0; chromeEventBuffer.removeAll()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.readChromeEvents(at: url) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        chromeEvents = source
        source.resume()
    }

    private func readChromeEvents(at url: URL) {
        guard chromeEventURL == url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            try file.seek(toOffset: chromeEventOffset)
            let data = try file.read(upToCount: 65536) ?? Data()
            chromeEventOffset += UInt64(data.count)
            chromeEventBuffer.append(data)
            while let newline = chromeEventBuffer.firstIndex(of: 10) {
                let line = Data(chromeEventBuffer.prefix(upTo: newline))
                chromeEventBuffer.removeSubrange(...newline)
                if let event = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                   Self.isChromeDisconnectEvent(event, session: chromeSession) {
                    invalidateChromeAccess()
                }
            }
        } catch { invalidateChromeAccess() }
    }

    private func scheduleChromeExpiry() {
        chromeExpiryTask?.cancel()
        guard chromeAccess == .connected, let session = chromeSession,
              let connectedAt, let lastBrowserUse else { return }
        let delay = max(0, min(connectedAt.addingTimeInterval(8 * 3600),
                               lastBrowserUse.addingTimeInterval(30 * 60)).timeIntervalSinceNow)
        chromeExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.chromeSession == session else { return }
            self.invalidateChromeAccess()
        }
    }


    /// Check process/expiry locally, then probe the existing socket while idle.
    /// The host-only probe never opens a connection or inspects browser content.
    func refreshChromeAccess() {
        guard chromeAccess == .connected else { return }
        if daemon?.isRunning != true || proxy?.isRunning != true ||
            chromePID.flatMap({ NSRunningApplication(processIdentifier: $0) })?.isTerminated != false ||
            Date().timeIntervalSince(connectedAt ?? .distantPast) >= 8 * 3600 ||
            Date().timeIntervalSince(lastBrowserUse ?? .distantPast) >= 30 * 60 {
            invalidateChromeAccess()
            return
        }
        guard !commandActive, !busy, !starting,
              let session = chromeSession, let pid = chromePID else { return }
        // Reserve synchronously so timer ticks and manual/planner actions cannot
        // race for the single MCP transport before the Task begins running.
        guard let owner = try? claimCommand() else { return }
        Task { @MainActor in
            defer { releaseCommand(owner) }
            do {
                let response = try await call(name: "browser_connection_status",
                    arguments: ["session": session, "pid": pid], timeout: 5)
                guard chromeSession == session, chromeAccess == .connected else { return }
                if !Self.chromeConnectionIsLive(response) { invalidateChromeAccess() }
            } catch {
                if chromeSession == session, chromeAccess == .connected { invalidateChromeAccess() }
            }
        }
    }

    static func chromeConnectionIsLive(_ response: [String: Any]) -> Bool {
        guard let result = response["result"] as? [String: Any],
              result["isError"] as? Bool != true,
              let details = result["structuredContent"] as? [String: Any] else { return false }
        return details["connected"] as? Bool == true
    }

    private func invalidateChromeAccess() {
        if chromeAccess != .notConnected {
            chromeAccess = .reconnectRequired
            chromeAccessMessage = "Connect Chrome in Permissions before using browser tools."
        }
        chromeExpiryTask?.cancel(); chromeExpiryTask = nil
        chromePID = nil; connectedAt = nil; lastBrowserUse = nil
    }

    static func isBrowserTool(_ name: String) -> Bool {
        name == "get_browser_state" || name.hasPrefix("browser_")
    }

    /// Only this manual UI entry point may prepare/attach Chrome. The command
    /// lease keeps setup and planner RPCs from overlapping on the shared host.
    func connectChromeFromSettings() async {
        guard let executable = Self.selectedExecutable else { return }
        let owner: UUID
        do { owner = try claimCommand() }
        catch { chromeAccessMessage = "Wait for the current CUA command to finish."; return }
        defer { releaseCommand(owner) }
        chromeAccess = .connecting
        let session = "muesli-chrome-setup-" + UUID().uuidString
        do {
            if let previousSession = chromeSession {
                await endCommand(session: previousSession)
                chromeSession = nil
            }
            // Restart only when adding the explicit manual grant to an older
            // ungranted host. The UI action itself is the authorization.
            if !manualProfileAuthorization && !CommandLine.arguments.contains("--trycua-authorize-existing-profile") {
                await stop()
            }
            manualProfileAuthorization = true
            chromeAccess = .connecting
            try await start(executable: executable)
            chromeAccessMessage = "Waiting for Chrome debugging and connection approval…"
            guard let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
                throw failure("Install Chrome before connecting browser access.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            let chrome: NSRunningApplication
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
                chrome = running
            } else {
                chrome = try await NSWorkspace.shared.openApplication(at: chromeURL, configuration: configuration)
            }
            let started = try await call(name: "start_session", arguments: ["session": session])
            guard (started["result"] as? [String: Any])?["isError"] as? Bool != true else {
                throw failure("Could not start Chrome connection setup.")
            }
            var openedSetup = false
            var needsApproval = false
            let deadline = Date().addingTimeInterval(180)
            while true {
                try Task.checkCancellation()
                guard !shuttingDown, !chrome.isTerminated else { throw failure("Chrome connection setup stopped.") }
                guard Date() < deadline else {
                    throw failure("Timed out waiting for Chrome debugging. Enable it, then click Reconnect.")
                }
                guard let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
                      let window = windows.first(where: {
                          ($0[kCGWindowOwnerPID as String] as? Int32) == chrome.processIdentifier &&
                          ($0[kCGWindowLayer as String] as? Int) == 0
                      }), let windowID = window[kCGWindowNumber as String] as? Int else {
                    chromeAccessMessage = "Open a Chrome window to continue connecting."
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                // Patched driver discovers and verifies the endpoint first. A
                // missing endpoint returns requires_setup without touching UI.
                let response = try await call(name: "browser_prepare", arguments: [
                    "pid": chrome.processIdentifier, "window_id": windowID, "session": session,
                    "strategy": ["kind": "existing_profile"],
                    "delivery_mode": needsApproval ? "foreground" : "background"],
                    timeout: min(120, deadline.timeIntervalSinceNow))
                switch Self.chromePreparationOutcome(response) {
                case .connected:
                    break
                case .waitingForApproval:
                    guard !needsApproval else { throw failure("Chrome connection approval was not granted.") }
                    chromeAccessMessage = "Approve Chrome’s browser connection prompt."
                    needsApproval = true
                    // Only a concrete consent refusal permits interactive attachment.
                    chrome.activate()
                    continue
                case .waitingForDebugging:
                    chromeAccessMessage = "Enable remote debugging in Chrome. Muesli will connect automatically; approve Chrome’s prompt if shown."
                    if !openedSetup {
                        configuration.activates = true
                        _ = try await NSWorkspace.shared.open(
                            [URL(string: "chrome://inspect/#remote-debugging")!],
                            withApplicationAt: chromeURL, configuration: configuration)
                        openedSetup = true
                    }
                    try await Task.sleep(for: .seconds(1))
                    continue
                case .failed(let message):
                    throw failure(message)
                }
                break
            }
            chromeSession = session
            chromePID = chrome.processIdentifier
            connectedAt = Date(); lastBrowserUse = Date()
            chromeAccess = .connected; chromeAccessMessage = nil
            let watched = try await call(name: "browser_connection_status", arguments: [
                "session": session, "pid": chrome.processIdentifier, "watch": true])
            if !Self.chromeConnectionIsLive(watched) { invalidateChromeAccess() }
            scheduleChromeExpiry()
        } catch {
            chromeAccess = .reconnectRequired
            chromeAccessMessage = error.localizedDescription
        }
        if chromeAccess != .connected { await endCommand(session: session) }
    }

    /// All planner browser dispatch goes through this gate, including forged
    /// calls. Inspection can detect a stale connection but cannot initiate setup.
    func callInBackground(name: String, arguments: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        refreshChromeAccess()
        if name == "browser_prepare" || (Self.isBrowserTool(name) && chromeAccess != .connected) {
            return ["result": ["isError": true, "content": [["type": "text", "text":
                "Chrome browser access requires connection in Muesli Settings > Permissions. Do not open Chrome setup during this command. Use Accessibility tools if appropriate, or report this prerequisite."]]]]
        }
        var scoped = arguments
        if Self.isBrowserTool(name), let chromeSession {
            scoped = Self.scopedArguments(arguments, session: chromeSession)
        }
        let response = try await call(name: name, arguments: scoped, timeout: timeout)
        if Self.isBrowserTool(name) {
            if Self.requiresChromeReconnect(response) {
                invalidateChromeAccess()
            } else {
                lastBrowserUse = Date()
                scheduleChromeExpiry()
            }
        }
        return response
    }

    enum ChromePreparationOutcome: Equatable {
        case connected, waitingForDebugging, waitingForApproval, failed(String)
    }

    static func chromePreparationOutcome(_ response: [String: Any]) -> ChromePreparationOutcome {
        let result = response["result"] as? [String: Any] ?? [:]
        let details = result["structuredContent"] as? [String: Any] ?? [:]
        let refusal = details["refusal"] as? [String: Any]
        if refusal?["code"] as? String == "browser_requires_setup" { return .waitingForDebugging }
        if refusal?["code"] as? String == "browser_consent_required" { return .waitingForApproval }
        if let message = refusal?["message"] as? String { return .failed(message) }
        if result["isError"] as? Bool != true, details["prepared"] as? Bool == true {
            return .connected
        }
        return .failed("Chrome did not confirm a connection. " + ComputerUseReferenceRuntime.observation(from: response).text)
    }

    static func requiresChromeReconnect(_ response: [String: Any]) -> Bool {
        let result = response["result"] as? [String: Any] ?? [:]
        let structured = result["structuredContent"] as? [String: Any] ?? [:]
        let refusal = structured["refusal"] as? [String: Any] ?? [:]
        guard let code = refusal["code"] as? String else { return false }
        return ["browser_requires_setup", "browser_consent_required", "browser_consent_revoked",
                "browser_reconnect_exhausted", "browser_route_unavailable"].contains(code)
    }

    private var commandOwner: UUID?
    private var executablePath: String?
    private var starting = false
    private var shuttingDown = false
    var processID: Int32? { daemon?.isRunning == true ? daemon?.processIdentifier : nil }

    func claimCommand() throws -> UUID {
        guard commandOwner == nil, !starting, !shuttingDown else { throw failure("Reference command already active or host shutting down") }
        let owner = UUID()
        commandOwner = owner
        commandActive = true
        return owner
    }

    func releaseCommand(_ owner: UUID) {
        if commandOwner == owner { commandOwner = nil; commandActive = false }
    }

    static func scopedArguments(_ arguments: [String: Any], session: String) -> [String: Any] {
        var scoped = arguments
        scoped["session"] = session
        scoped.removeValue(forKey: "_session_id")
        return scoped
    }

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
        guard !starting, !shuttingDown else { throw failure("Reference host is starting or shutting down") }
        if executablePath == executable, daemon?.isRunning == true, proxy?.isRunning == true, !tools.isEmpty {
            return
        }
        starting = true
        defer { starting = false }
        if daemon != nil || proxy != nil { await stop() }
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.muesli.dev") == true,
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw failure("Reference driver requires a dev host and an executable path")
        }
        // macOS Unix sockets have a short sun_path limit; the per-user
        // temporary directory plus a UUID exceeds it on this host.
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("muesli-reference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        directory = root
        let eventsURL = root.appendingPathComponent("chrome-events.jsonl")
        try observeChromeEvents(at: eventsURL)
        let socket = root.appendingPathComponent("driver.sock").path
        let logURL = root.appendingPathComponent("driver.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forWritingTo: logURL)
        var environment = ProcessInfo.processInfo.environment
        environment["CUA_DRIVER_EMBEDDED"] = "1"
        environment["MUESLI_CHROME_MANUAL_RECONNECT"] = "1"
        // Chrome permission persists at profile scope; each task window must
        // independently pass the driver's exact native/CDP ownership proof.
        environment["MUESLI_CHROME_PROFILE_WINDOW_SCOPE"] = "1"
        environment["MUESLI_CHROME_EVENTS_PATH"] = eventsURL.path
        environment["CUA_DRIVER_HOST_BUNDLE_ID"] = Bundle.main.bundleIdentifier
        environment["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = "false"
        // Do not inherit an ambient approval bypass from the shell.
        environment["CUA_DRIVER_PERMISSION_MODE"] = "standard"
        environment.removeValue(forKey: "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS")
        do {
            let service = Process()
            service.executableURL = URL(fileURLWithPath: executable)
            service.arguments = ["serve", "--embedded", "--socket", socket]
            // Explicit dev-host launch authorization, never derived from a
            // planner argument or an ambient permission bypass.
            let existingProfileAuthorized = manualProfileAuthorization || CommandLine.arguments.contains("--trycua-authorize-existing-profile")
            if existingProfileAuthorized {
                service.arguments?.append(contentsOf: ["--grant", "existing-profile"])
            }
            service.environment = environment
            service.standardOutput = log; service.standardError = log
            service.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.directory == root else { return }
                    self.invalidateChromeAccess()
                }
            }
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
            client.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.directory == root else { return }
                    self.invalidateChromeAccess()
                }
            }
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
            executablePath = executable
            try save(catalog, name: "tools.json")
            try save(try await call(name: "check_permissions", arguments: ["prompt": false]), name: "permissions.json")
            try save(["pid": service.processIdentifier, "socket": socket, "executable": executable,
                      "host": Bundle.main.bundleIdentifier ?? "", "permission_mode": "standard",
                      "existing_profile_authorized": existingProfileAuthorized], name: "endpoint.json")
            fputs("[muesli-reference] Ready; evidence: \(root.path)\n", stderr)
        } catch {
            try? save(["error": error.localizedDescription], name: "failure.json")
            await stop()
            throw error
        }
    }

    func call(name: String, arguments: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        let started = Date()
        let result = try await request(method: "tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
        try save(["tool": name, "arguments": arguments, "response": result,
                  "duration_ms": Date().timeIntervalSince(started) * 1000], name: "call-\(nextID).json")
        return result
    }

    private func request(method: String, params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard !busy else { throw failure("Concurrent reference requests are not supported") }
        busy = true
        defer { busy = false }
        nextID += 1
        let id = nextID
        // Once a request has been sent, cancellation/transport failure leaves
        // its side effects uncertain. Invalidate the connection before reuse.
        var completed = false
        defer { if !completed { terminateImmediately() } }
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
                if message["id"] as? Int == id {
                    completed = true
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

    private func terminateImmediately() {
        invalidateChromeAccess()
        chromeSession = nil
        for child in [proxy, daemon].compactMap({ $0 }) where child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
        executablePath = nil
        tools = []
    }

    func shutdown() async {
        shuttingDown = true
        await stop()
    }

    func endCommand(session: String) async {
        guard daemon?.isRunning == true, proxy?.isRunning == true else {
            await stop()
            return
        }
        do {
            let response = try await call(name: "end_session", arguments: ["session": session])
            if (response["result"] as? [String: Any])?["isError"] as? Bool == true {
                await stop()
            }
        } catch { await stop() }
    }

    func stop() async {
        chromeEvents?.cancel(); chromeEvents = nil; chromeEventURL = nil
        invalidateChromeAccess()
        chromeSession = nil
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
        executablePath = nil; tools = []; serverVersion = "unknown"
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("endpoint.json")) }
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "MuesliReferenceDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
