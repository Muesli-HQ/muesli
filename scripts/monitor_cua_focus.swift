// Read-only benchmark observer. Never activates apps, sends input, or kills CUA.
// Hardware event ages are correlation evidence, not proof of user intent.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let started = Date()
let url = root.appendingPathComponent("focus.jsonl")
FileManager.default.createFile(atPath: url.path, contents: nil)
let log = try FileHandle(forWritingTo: url)
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func record(_ reason: String) {
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop-monitor").path) { exit(0) }
    let app = NSWorkspace.shared.frontmostApplication
    let pid = app?.processIdentifier ?? -1
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let normal = windows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    let front = normal.first { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
    var ages: [String: Double] = [:]
    for (name, type): (String, CGEventType) in [("left_mouse_down", .leftMouseDown), ("right_mouse_down", .rightMouseDown), ("key_down", .keyDown), ("flags_changed", .flagsChanged)] {
        let age = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
        if age.isFinite { ages[name] = age }
    }
    let row: [String: Any] = ["time": formatter.string(from: Date()), "elapsed": Date().timeIntervalSince(started),
        "reason": reason, "pid": Int(pid), "app": app?.bundleIdentifier ?? "unknown",
        "window": front?[kCGWindowNumber as String] as? Int ?? -1,
        "window_source": "frontmost_app_top_window_order_proxy",
        "hardware_event_ages": ages,
        "window_order": normal.map { ["pid": $0[kCGWindowOwnerPID as String] as? Int ?? -1, "window": $0[kCGWindowNumber as String] as? Int ?? -1] }]
    if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
        log.write(data); log.write(Data([10]))
    }
}
record("initial")
let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in record("activation") }
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in record("sample") }
RunLoop.main.run()
