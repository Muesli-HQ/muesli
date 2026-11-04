import Foundation

/// One bounded summary after 60 seconds without a completed suggestion (or a
/// model switch). No per-keystroke requests, application identity, text or timing.
@MainActor
final class CotypistAnalytics {
    private var shown = 0
    private var accepted = 0
    private var dismissed = 0
    private var model: AnalyticsModel?
    private var token: String?
    private var flushTask: Task<Void, Never>?
    func record(accepted didAccept: Bool, model next: AnalyticsModel) {
        let current = ProductAnalytics.emitter.token()
        if token != current { reset() }
        guard current != nil else { return }
        if model != nil, model != next { flush() }
        token = current; model = next
        shown = min(21, shown + 1)
        if didAccept { accepted = min(21, accepted + 1) }
        else { dismissed = min(21, dismissed + 1) }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.flush()
        }
    }
    func flush() {
        if shown > 0 {
            ProductAnalytics.emitter.emit(.init(feature: .cotypist, kind: .session_finished,
                fields: [.shown: ProductAnalytics.bucket(shown), .accepted: ProductAnalytics.bucket(accepted),
                         .dismissed: ProductAnalytics.bucket(dismissed)], model: model), token: token)
        }
        reset()
    }
    private func reset() {
        flushTask?.cancel(); flushTask = nil
        shown = 0; accepted = 0; dismissed = 0; model = nil; token = nil
    }
}
