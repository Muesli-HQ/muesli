import Foundation

#if canImport(OSLog)
import OSLog
#else
import Logging
#endif

/// Platform-neutral logging facade.
///
/// macOS keeps OSLog (same subsystem/category shape used by the app); Windows
/// routes through Swift Log. Business logic depends on this facade instead of
/// scattering `#if` checks or importing a platform logger directly.
struct MuesliLog: @unchecked Sendable {
    #if canImport(OSLog)
    private let osLogger: Logger
    #else
    private let swiftLogger: Logging.Logger
    #endif

    init(subsystem: String, category: String) {
        #if canImport(OSLog)
        self.osLogger = Logger(subsystem: subsystem, category: category)
        #else
        self.swiftLogger = Logging.Logger(label: "\(subsystem).\(category)")
        #endif
    }

    func trace(_ message: @autoclosure () -> String) { log(level: .trace, message()) }
    func debug(_ message: @autoclosure () -> String) { log(level: .debug, message()) }
    func info(_ message: @autoclosure () -> String) { log(level: .info, message()) }
    func notice(_ message: @autoclosure () -> String) { log(level: .notice, message()) }
    func warning(_ message: @autoclosure () -> String) { log(level: .warning, message()) }
    func error(_ message: @autoclosure () -> String) { log(level: .error, message()) }
    func critical(_ message: @autoclosure () -> String) { log(level: .critical, message()) }

    private enum Level {
        case trace, debug, info, notice, warning, error, critical
    }

    private func log(level: Level, _ message: String) {
        #if canImport(OSLog)
        switch level {
        case .trace: osLogger.trace("\(message, privacy: .public)")
        case .debug: osLogger.debug("\(message, privacy: .public)")
        case .info: osLogger.info("\(message, privacy: .public)")
        case .notice: osLogger.notice("\(message, privacy: .public)")
        case .warning: osLogger.warning("\(message, privacy: .public)")
        case .error: osLogger.error("\(message, privacy: .public)")
        case .critical: osLogger.critical("\(message, privacy: .public)")
        }
        #else
        switch level {
        case .trace: swiftLogger.trace("\(message)")
        case .debug: swiftLogger.debug("\(message)")
        case .info: swiftLogger.info("\(message)")
        case .notice: swiftLogger.notice("\(message)")
        case .warning: swiftLogger.warning("\(message)")
        case .error: swiftLogger.error("\(message)")
        case .critical: swiftLogger.critical("\(message)")
        }
        #endif
    }
}
