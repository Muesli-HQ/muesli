import Foundation
import MuesliCore

/// Feature preferences select a model; connections and transports stay shared.
/// Resolve once at request start without modifying another feature's defaults.
struct FeatureTextModelSelection: Codable, Equatable, Sendable {
    var backend: String
    var model: String

    func configuration(from config: AppConfig) -> AppConfig {
        MeetingSummaryBackendOption.resolved(backend).summaryConfiguration(from: config, model: model)
    }
}

extension AppConfig {
    var timeTurnerGenerationConfig: AppConfig {
        recapModelSelection?.configuration(from: self) ?? self
    }
}
