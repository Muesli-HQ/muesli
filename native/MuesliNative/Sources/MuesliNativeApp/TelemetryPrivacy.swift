import Foundation
import TelemetryDeck

/// Device-local preference, deliberately outside AppConfig/CloudKit and exports.
/// A generation travels only as far as our transport; it is stripped before upload.
final class TelemetryPrivacyGate: @unchecked Sendable {
    static let disabledKey = "muesli.disableAnonymousAnalytics"
    static let generationKey = "muesli.analyticsConsentGeneration"
    static let localMarker = "muesli.localConsentGeneration"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var disabled: Bool
    private var generation: String
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private let configured: Bool

    init(defaults: UserDefaults, configured: Bool) {
        self.defaults = defaults
        self.configured = configured
        disabled = defaults.bool(forKey: Self.disabledKey)
        generation = defaults.string(forKey: Self.generationKey) ?? "legacy"
    }

    var consentToken: String? { lock.withLock { configured && !disabled ? generation : nil } }
    var isDisabled: Bool { lock.withLock { disabled } }
    var parameters: [String: String] {
        lock.withLock { [Self.localMarker: disabled ? "disabled" : generation] }
    }

    func setDisabled(_ value: Bool) {
        lock.withLock {
            guard disabled != value else { return }
            disabled = value
            // Rotating on both transitions prevents replay after opting back in.
            generation = UUID().uuidString
            defaults.set(generation, forKey: Self.generationKey)
            defaults.set(value, forKey: Self.disabledKey)
            if value {
                for task in tasks.values { task.cancel() }
                tasks.removeAll()
            }
        }
    }

    /// Parse/encode off the consent lock: main-thread emitters and the opt-out UI
    /// must never wait for a cached batch to be serialized.
    private func filteredBody(_ body: Data?, disabled: Bool, generation: String) -> Data? {
        guard configured, !disabled, let body,
              let signals = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return nil }
        let allowed = signals.compactMap { signal -> [String: Any]? in
            guard var payload = signal["payload"] as? [String: String] else { return nil }
            let marker = payload.removeValue(forKey: Self.localMarker) ?? "legacy"
            guard marker == generation else { return nil }
            // SDK cumulative retention metadata can include time spent opted out.
            // After the first preference transition, never transmit those totals.
            if generation != "legacy" {
                payload = payload.filter {
                    !$0.key.hasPrefix("TelemetryDeck.Retention.")
                        && $0.key != "TelemetryDeck.Acquisition.firstSessionDate"
                }
            }
            var clean = signal
            clean["payload"] = payload
            return clean
        }
        guard !allowed.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: allowed)
    }

    // Internal for synthetic tests; no event content leaves the machine.
    func filter(_ body: Data?) -> Data? {
        let state = lock.withLock { (disabled, generation) }
        return filteredBody(body, disabled: state.0, generation: state.1)
    }

    func send(_ request: URLRequest, session: URLSession,
              completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask? {
        let state = lock.withLock { (disabled, generation) }
        guard let body = filteredBody(request.httpBody, disabled: state.0, generation: state.1) else { return nil }
        return lock.withLock {
            // Consent may have changed while the utility thread serialized the batch.
            // Check and resume atomically with respect to setDisabled.
            guard !disabled, generation == state.1 else { return nil }
            var clean = request
            clean.httpBody = body
            clean.setValue(nil, forHTTPHeaderField: "Content-Length")
            let id = UUID()
            let task = session.dataTask(with: clean) { [weak self] data, response, error in
                _ = self?.lock.withLock { self?.tasks.removeValue(forKey: id) }
                completion(data, response, error)
            }
            tasks[id] = task
            task.resume()
            return task
        }
    }
}

/// The SDK's analyticsDisabled flag gates new events, but SDK 2.11.0 uploads
/// cached events independently. Intercept only its dedicated URLSession.
final class TelemetryPrivacyProtocol: URLProtocol, @unchecked Sendable {
    private var forwardingTask: URLSessionDataTask?
    private static let forwardingSession = URLSession(configuration: .ephemeral)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var outgoing = request
        // URLSession can convert httpBody into a stream before invoking a protocol.
        if outgoing.httpBody == nil, let stream = outgoing.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            outgoing.httpBodyStream = nil
            outgoing.httpBody = data
        }
        forwardingTask = MuesliTelemetry.privacy.send(outgoing, session: Self.forwardingSession) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if forwardingTask == nil {
            // Acknowledge locally: dropped batches must not be retried or restored
            // by the SDK after the user opts back in. No network request is made.
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { forwardingTask?.cancel() }
}

enum MuesliTelemetry {
    @MainActor private static var sdkConfig: TelemetryDeck.Config?
    static let privacy = TelemetryPrivacyGate(defaults: .standard,
                                             configured: TelemetryRuntimeConfiguration.current().isEnabled)

    private static let queue = DispatchQueue(label: "com.muesli.telemetry-sdk", qos: .utility)
    private static let queueLock = NSLock()
    private static var pending = 0

    private static func enqueue(_ operation: @escaping @Sendable (String) -> Void) {
        guard let token = privacy.consentToken else { return }
        guard queueLock.withLock({ if pending >= 256 { return false }; pending += 1; return true }) else { return }
        queue.async {
            defer { queueLock.withLock { pending -= 1 } }
            guard privacy.consentToken == token else { return }
            operation(token)
        }
    }
    static func signal(_ name: String, parameters: [String: String] = [:]) {
        if let event = ProductAnalytics.migratedEvent(name) {
            ProductAnalytics.emitter.emit(event, token: privacy.consentToken)
            return
        }
        enqueue { token in
            var safe = parameters
            safe[TelemetryPrivacyGate.localMarker] = token
            TelemetryDeck.signal(name, parameters: safe)
        }
    }
    static func errorOccurred(id: String, category: ErrorCategory, message: String?, parameters: [String: String]) {
        enqueue { token in
            var safe = parameters
            safe[TelemetryPrivacyGate.localMarker] = token
            TelemetryDeck.errorOccurred(id: id, category: category, message: nil, parameters: safe)
        }
    }
    static func sendProductEvent(_ event: ProductAnalyticsEvent, token: String) {
        guard privacy.consentToken == token else { return }
        var parameters = event.parameters
        parameters[TelemetryPrivacyGate.localMarker] = token
        TelemetryDeck.signal(event.name, parameters: parameters)
    }

    // Called only by the serial utility worker after its durable checkpoint.
    // Numeric aggregation is intentionally separate from finite lifecycle fields.
    static func sendWordBatch(_ batch: DictationWordBatch, token: String) {
        guard privacy.consentToken == token, batch.words > 0 else { return }
        TelemetryDeck.signal("dictation.words_\(batch.kind.rawValue)", parameters: [
            "product.schema": "1",
            "coverage": "local_saved_dictations",
            TelemetryPrivacyGate.localMarker: token
        ], floatValue: Double(batch.words))
    }

    @MainActor static func initialize() {
        let runtime = TelemetryRuntimeConfiguration.current()
        let config = TelemetryDeck.Config(appID: runtime.sdkAppID)
        // Use a dedicated session so no provider, sync or update requests are affected.
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [TelemetryPrivacyProtocol.self]
        config.urlSession = URLSession(configuration: session)
        config.analyticsDisabled = !runtime.isEnabled || privacy.isDisabled
        config.defaultParameters = { runtime.defaultParameters.merging(privacy.parameters) { _, new in new } }
        config.logHandler = nil
        sdkConfig = config
        TelemetryDeck.initialize(config: config)
    }

    @MainActor static func setDisabled(_ disabled: Bool) {
        privacy.setDisabled(disabled)
        DictationWordAnalytics.shared.consentChanged()
        sdkConfig?.analyticsDisabled = disabled || !TelemetryRuntimeConfiguration.current().isEnabled
    }
}
