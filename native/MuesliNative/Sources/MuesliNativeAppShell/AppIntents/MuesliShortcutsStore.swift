import MuesliCore
import MuesliNativeApp

/// Shared DB access for read-only App Intents. Opens its own connection
/// rather than routing through MuesliController.current, so "get last
/// dictation/meeting" Shortcuts still work even when Muesli isn't running.
/// Uses AppIdentity.supportDirectoryURL (reads the running process's own
/// Bundle.main) rather than the MuesliPaths default, so this resolves the
/// correct per-identity database — MuesliDev vs Muesli vs MuesliCanary —
/// instead of always reading production data regardless of which app is
/// actually running.
enum MuesliShortcutsStore {
    static func open() throws -> DictationStore {
        let store = DictationStore(
            databaseURL: AppIdentity.supportDirectoryURL.appendingPathComponent("muesli.db")
        )
        try store.migrateIfNeeded()
        return store
    }
}
