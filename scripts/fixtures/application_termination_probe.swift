import AppKit

// Run in a separate process: a real AppKit termination loop cannot safely be
// exercised inside the test runner. The watchdog turns a deadlock into failure.
@MainActor
private final class TerminationProbe: NSObject, NSApplicationDelegate {
    let stuck: Bool
    let direct: Bool
    init(stuck: Bool, direct: Bool) { self.stuck = stuck; self.direct = direct }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if direct { NSApp.terminate(nil) }
            else { ApplicationTermination.request() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let finished = await ShutdownDeadline.run(seconds: 0.2) { [stuck] in
                // Simulate an unresponsive job without leaking a continuation.
                try? await Task.sleep(for: .milliseconds(stuck ? 60_000 : 10))
            }
            guard finished == !stuck else { exit(3) }
            print(stuck ? "deadline replied" : "shutdown replied")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ApplicationTerminationProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = TerminationProbe(stuck: CommandLine.arguments.contains("--stuck"),
                                        direct: CommandLine.arguments.contains("--direct"))
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            fputs("termination deadlocked: shutdown/deadline could not reply\n", stderr)
            exit(2)
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
