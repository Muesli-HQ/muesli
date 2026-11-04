import Foundation
import MuesliCore

/// Only numerical totals leave this worker. IDs are used in memory to separate
/// the startup snapshot from concurrent local saves; they are never uploaded.
struct DictationWordBatch: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case baseline, daily }
    let kind: Kind
    let words: Int
}

struct DictationWordState: Codable, Sendable {
    var version = 1
    var baselineAttempted = false
    var consent: String?
    var day: Int
    var pending = 0

    mutating func reconcile(token: String?) {
        if consent != token { pending = 0; consent = token }
        // Opting out permanently closes eligibility for a historical backfill.
        if token == nil || token != "legacy" { baselineAttempted = true }
    }
    mutating func baseline(words: Int, token: String?) -> DictationWordBatch? {
        reconcile(token: token)
        guard !baselineAttempted, token != nil else { return nil }
        baselineAttempted = true
        return words > 0 ? .init(kind: .baseline, words: words) : nil
    }
    mutating func flush(today: Int, token: String?) -> DictationWordBatch? {
        reconcile(token: token)
        guard today > day else { return nil }
        day = today
        let words = pending
        pending = 0
        return token != nil && words > 0 ? .init(kind: .daily, words: words) : nil
    }
    mutating func add(_ words: Int, capturedToken: String?, currentToken: String?) {
        reconcile(token: currentToken)
        guard let capturedToken, capturedToken == currentToken, words > 0 else { return }
        let (sum, overflow) = pending.addingReportingOverflow(words)
        if !overflow { pending = sum }
    }
}

final class DictationWordAnalytics: @unchecked Sendable {
    static let shared = DictationWordAnalytics()
    private let queue = DispatchQueue(label: "com.muesli.dictation-word-analytics", qos: .utility)
    private let lock = NSLock()
    private var queued = 0
    private var state: DictationWordState?
    private var stateURL: URL?
    private var cutoff: Int64 = 0
    private var timer: DispatchSourceTimer?
    private let token: @Sendable () -> String?
    private let sink: @Sendable (DictationWordBatch, String) -> Void

    init(token: @escaping @Sendable () -> String? = { MuesliTelemetry.privacy.consentToken },
         sink: @escaping @Sendable (DictationWordBatch, String) -> Void = { MuesliTelemetry.sendWordBatch($0, token: $1) }) {
        self.token = token
        self.sink = sink
    }
    static func day(_ date: Date = Date()) -> Int { Int(floor(date.timeIntervalSince1970 / 86_400)) }

    func start(databaseURL: URL, stateURL: URL) {
        let launchToken = token()
        queue.async { [self] in
            guard self.stateURL == nil else { return }
            self.stateURL = stateURL
            do {
                let today = Self.day()
                if FileManager.default.fileExists(atPath: stateURL.path) {
                    let loaded = try JSONDecoder().decode(DictationWordState.self, from: Data(contentsOf: stateURL))
                    guard loaded.version == 1 else { return } // Fail closed on unknown/corrupt state.
                    state = loaded
                } else {
                    state = .init(consent: launchToken, day: today)
                }
                let snapshot = try DictationStore(databaseURL: databaseURL, readOnly: true).localDictationWordBaseline()
                cutoff = snapshot.lastID
                // A consent transition while reading history must not expose a baseline.
                if launchToken != token() { state?.baselineAttempted = true }
                let baseline = state?.baseline(words: snapshot.words, token: token())
                persistAndSend(baseline)
                flush()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(15))
                timer.setEventHandler { [weak self] in self?.flush() }
                self.timer = timer
                timer.resume()
            } catch {
                // Never retry a baseline using an uncertain checkpoint.
                state = nil
            }
        }
    }
    func record(id: Int64, words: Int) {
        guard let captured = token(), words > 0 else { return }
        guard lock.withLock({ if queued >= 256 { return false }; queued += 1; return true }) else { return }
        queue.async { [self] in
            defer { lock.withLock { queued -= 1 } }
            guard state != nil, id > cutoff else { return }
            flush()
            state?.add(words, capturedToken: captured, currentToken: token())
            persistAndSend(nil)
        }
    }
    func consentChanged() {
        queue.async { [self] in
            state?.reconcile(token: token())
            persistAndSend(nil)
        }
    }
    private func flush() {
        guard state != nil else { return }
        let batch = state?.flush(today: Self.day(), token: token())
        persistAndSend(batch)
    }
    private func persistAndSend(_ batch: DictationWordBatch?) {
        guard let state, let stateURL else { return }
        do {
            // Persist consumption before handing off to the SDK. App restarts never
            // re-submit the baseline/batch. A crash at this boundary may undercount.
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            if let batch, let consent = state.consent, token() == consent { sink(batch, consent) }
        } catch {
            self.state = nil // Fail closed rather than risk replaying a baseline.
        }
    }
    func drain() { queue.sync {} } // Synthetic tests only.
    deinit { timer?.cancel() }
}
