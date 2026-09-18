import Foundation

public enum MuesliPaths {
    public static func defaultSupportDirectoryURL(appName: String = "Muesli") -> URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
        #else
        // Windows/Linux use the platform application-support location. The
        // shipping Windows app owns its own %APPDATA%\muesli paths; this default
        // only keeps MuesliCore usable in isolation.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(appName, isDirectory: true)
        #endif
    }

    public static func defaultDatabaseURL(appName: String = "Muesli") -> URL {
        defaultSupportDirectoryURL(appName: appName).appendingPathComponent("muesli.db")
    }
}

public enum MuesliNotifications {
    public static let dataDidChange = Notification.Name("com.muesli.dataChanged")

    public static func postDataDidChange() {
        #if os(macOS)
        // Cross-process notification on macOS; other platforms use the
        // in-process NotificationCenter (no DistributedNotificationCenter).
        DistributedNotificationCenter.default().post(name: dataDidChange, object: nil)
        #else
        NotificationCenter.default.post(name: dataDidChange, object: nil)
        #endif
    }
}
