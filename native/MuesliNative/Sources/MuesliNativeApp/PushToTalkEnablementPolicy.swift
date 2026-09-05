import Foundation

struct PushToTalkEnablementIntentStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "pushToTalk.pendingEnable"
    ) {
        self.defaults = defaults
        self.key = key
    }

    var isPending: Bool {
        defaults.bool(forKey: key)
    }

    func markPending() {
        defaults.set(true, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

enum PushToTalkEnablementPolicy {
    enum Outcome: Equatable {
        case disabled
        case ready
        case waitForPermissions
    }

    static func shouldStartDictationHotkeyMonitor(
        hasCompletedOnboarding: Bool,
        hasDictationPermissions: Bool,
        isEnabled: Bool
    ) -> Bool {
        hasCompletedOnboarding && hasDictationPermissions && isEnabled
    }

    static func shouldReconcilePendingEnable(
        hasCompletedOnboarding: Bool,
        isPending: Bool
    ) -> Bool {
        hasCompletedOnboarding && isPending
    }

    static func outcome(
        isEnabled: Bool,
        hasDictationPermissions: Bool
    ) -> Outcome {
        guard isEnabled else { return .disabled }
        return hasDictationPermissions ? .ready : .waitForPermissions
    }
}
