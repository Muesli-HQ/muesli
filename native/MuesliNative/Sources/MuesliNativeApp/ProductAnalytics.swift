import Foundation

/// Product events accept finite fields only. Content, IDs, paths and raw errors
/// cannot be passed through this API. SDK work runs on a bounded utility queue.
enum AnalyticsFeature: String, Sendable, CaseIterable {
    case onboarding, model_setup, dictation, meeting, meeting_transcription, meeting_summary
    case chat, quill, computer_use, cotypist, time_turner, recap, search, workflow
    case cleanup, bridge, icloud_sync, vidshot, meeting_video, meeting_people, streaming_dictation
}
enum AnalyticsOutcome: String, Sendable { case success, cancelled, failed, blocked, discarded, partial }
enum AnalyticsField: String, Sendable {
    case stage, mode, source, delivery, saved, action, scope, cleanup, route, results, opened
    case during_meeting, people_viewed
    case shown, accepted, dismissed, feature, attempt_kind
}
enum AnalyticsValue: String, Sendable {
    case buffered, native_stream, parakeet, whisper, bodhan
    case capture, transcription, generation, delivery, storage, setup, permission, download, load
    case hold, toggle, rewrite, question, settings, desktop, manual, live, imported, postprocess
    case yes, no, unknown, success, failed, blocked, cancelled, partial, discarded
    case copy, apply, follow_up, export, citation_open, selected, all, none, initial, retry, recovery
    case zero, one, two_to_five, six_to_twenty, over_twenty
    case dictionary, formatting, bridge, sync, recap, time_turner
    case microphone, accessibility, input_monitoring, welcome, use_case, models, complete, discovery, link, reconnect, reset
}
struct AnalyticsModel: Sendable, Equatable {
    let provider: String
    let model: String
    // Creation is restricted to the catalog sanitizer in this module.
    init(provider: String, model: String, providers: Set<String>, models: Set<String>) {
        self.provider = providers.contains(provider) ? provider : "custom"
        self.model = models.contains(model) ? model : (model.isEmpty ? "unknown" : "custom")
    }
}
/// These categories are the only Chat source metadata that can leave the app.
enum ChatAnalyticsSource: String, Hashable, Sendable {
    case meeting, dictation, command, quill, cotypist, screen_history, chat, recap, vidshot
    case image, pdf, markdown, text

    // Keys come from the validated SQL plan, never from raw model arguments.
    static let sqlTables: [String: Self] = [
        "meetings": .meeting, "dictations": .dictation, "commands": .command,
        "quill": .quill, "cotypist": .cotypist, "screens": .screen_history,
        "chats": .chat, "recaps": .recap, "vidshots": .vidshot,
    ]
}

struct ProductAnalyticsEvent: Sendable {
    enum Kind: String, Sendable { case started, finished, opened, source_used, step_finished, result_action, session_finished, activation_finished, completed }
    let feature: AnalyticsFeature
    let kind: Kind
    var outcome: AnalyticsOutcome? = nil
    var fields: [AnalyticsField: AnalyticsValue] = [:]
    var model: AnalyticsModel? = nil
    var chatSource: ChatAnalyticsSource? = nil
    var name: String { "\(feature.rawValue).\(kind.rawValue)" }
    var parameters: [String: String] {
        var result = ["product.schema": "1"]
        for (key, value) in fields { result[key.rawValue] = value.rawValue }
        if let chatSource { result["source"] = chatSource.rawValue }
        result["outcome"] = outcome?.rawValue
        result["provider"] = model?.provider
        result["model"] = model?.model
        return result
    }
}

final class ProductAnalyticsEmitter: @unchecked Sendable {
    typealias Sink = @Sendable (ProductAnalyticsEvent, String) -> Void
    private let queue = DispatchQueue(label: "com.muesli.product-analytics", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private let capacity: Int
    private let consent: @Sendable () -> String?
    private let sink: Sink

    init(capacity: Int = 256, consent: @escaping @Sendable () -> String?, sink: @escaping Sink) {
        self.capacity = capacity; self.consent = consent; self.sink = sink
    }
    func token() -> String? { consent() }
    func emit(_ event: ProductAnalyticsEvent, token: String?) {
        guard let token else { return }
        let admitted = lock.withLock { () -> Bool in
            guard pending < capacity else { return false }; pending += 1; return true
        }
        guard admitted else { return }
        queue.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            guard consent() == token else { return }
            sink(event, token)
        }
    }
    // For tests/benchmarks only; production never waits for telemetry.
    func drain() { queue.sync {} }
}

final class AnalyticsAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var reportedChatSources: Set<ChatAnalyticsSource> = []
    private let emitter: ProductAnalyticsEmitter
    private let token: String?
    private let feature: AnalyticsFeature
    private let fields: [AnalyticsField: AnalyticsValue]
    private let model: AnalyticsModel?
    init(_ feature: AnalyticsFeature, fields: [AnalyticsField: AnalyticsValue] = [:], model: AnalyticsModel? = nil,
         emitter: ProductAnalyticsEmitter = ProductAnalytics.emitter) {
        self.feature = feature; self.fields = fields; self.model = model; self.emitter = emitter
        token = emitter.token()
        emitter.emit(.init(feature: feature, kind: .started, fields: fields, model: model), token: token)
    }
    func usedChatSource(_ source: ChatAnalyticsSource) {
        guard feature == .chat, token != nil,
              lock.withLock({ !finished && reportedChatSources.insert(source).inserted }) else { return }
        emitter.emit(.init(feature: .chat, kind: .source_used, chatSource: source), token: token)
    }

    func finish(_ outcome: AnalyticsOutcome, fields extra: [AnalyticsField: AnalyticsValue] = [:], model actual: AnalyticsModel? = nil) {
        guard lock.withLock({ if finished { return false }; finished = true; return true }) else { return }
        emitter.emit(.init(feature: feature, kind: .finished, outcome: outcome,
                           fields: fields.merging(extra) { _, new in new }, model: actual ?? model), token: token)
    }
    deinit { finish(.cancelled) }
}

enum ProductAnalytics {
    static let emitter = ProductAnalyticsEmitter(consent: { MuesliTelemetry.privacy.consentToken }) {
        MuesliTelemetry.sendProductEvent($0, token: $1)
    }
    static func event(_ feature: AnalyticsFeature, _ kind: ProductAnalyticsEvent.Kind,
                      outcome: AnalyticsOutcome? = nil, fields: [AnalyticsField: AnalyticsValue] = [:], model: AnalyticsModel? = nil) {
        emitter.emit(.init(feature: feature, kind: kind, outcome: outcome, fields: fields, model: model), token: MuesliTelemetry.privacy.bestEffortConsentToken)
    }
    static func bucket(_ count: Int) -> AnalyticsValue {
        switch count { case ...0: .zero; case 1: .one; case 2...5: .two_to_five; case 6...20: .six_to_twenty; default: .over_twenty }
    }
}

extension AnalyticsAttempt {
    static func measure<T>(_ feature: AnalyticsFeature?, fields: [AnalyticsField: AnalyticsValue] = [:],
                           model: AnalyticsModel? = nil, operation: () async throws -> T) async rethrows -> T {
        let attempt = feature.map { AnalyticsAttempt($0, fields: fields, model: model) }
        do {
            let value = try await operation()
            attempt?.finish(.success)
            return value
        } catch {
            attempt?.finish(error is CancellationError || Task.isCancelled ? .cancelled : .failed)
            throw error
        }
    }
}


extension ProductAnalytics {
    /// Migration of finite legacy lifecycle names. Parameters intentionally do not
    /// cross over: only lifecycle/stage/outcome are needed for these setup funnels.
    static func migratedEvent(_ name: String) -> ProductAnalyticsEvent? {
        let prefixes: [(String, AnalyticsFeature, AnalyticsValue)] = [
            ("bridge_device_discovery_", .bridge, .discovery),
            ("bridge_enable_", .bridge, .link),
            ("icloud_legacy_reconnect_", .icloud_sync, .reconnect),
            ("icloud_sync_reset_", .icloud_sync, .reset)]
        for (prefix, feature, stage) in prefixes where name.hasPrefix(prefix) {
            switch String(name.dropFirst(prefix.count)) {
            case "started": return .init(feature: feature, kind: .started, fields: [.stage: stage])
            case "completed": return .init(feature: feature, kind: .finished, outcome: .success, fields: [.stage: stage])
            case "failed", "timed_out": return .init(feature: feature, kind: .finished, outcome: .failed, fields: [.stage: stage])
            case "cancelled": return .init(feature: feature, kind: .finished, outcome: .cancelled, fields: [.stage: stage])
            default: return nil
            }
        }
        return nil
    }
}
