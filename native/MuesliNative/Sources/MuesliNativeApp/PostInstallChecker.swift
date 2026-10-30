import AppKit
import Foundation

private final class PostInstallSafetyTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var item: DispatchWorkItem?

    func schedule(after delay: DispatchTimeInterval, execute block: @escaping () -> Void) {
        let workItem = DispatchWorkItem(block: block)
        lock.lock()
        item = workItem
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancel() {
        lock.lock()
        item?.cancel()
        item = nil
        lock.unlock()
    }
}

private final class PostInstallCleanupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didRun = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didRun else { return false }
        didRun = true
        return true
    }
}

@MainActor
enum PostInstallChecker {
    private static var hasPresented = false
    private static let keptDMGPathsDefaultsKey = "post_install_checker_kept_dmg_paths"
    // P2: hold a reference so the task isn't immediately discarded.
    private static var mountedDMGCheckTask: Task<Void, Never>?
    private static var installTask: Task<Void, Never>?

    private struct InstallWorkResult: Sendable {
        let volumePath: String
        let sourceDMGPath: String?
    }

    static func check() {
        guard !hasPresented else { return }
        hasPresented = true

        let bundlePath = Bundle.main.bundlePath
        let bundleName = URL(fileURLWithPath: bundlePath).lastPathComponent
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent

        if bundlePath.hasPrefix("/Volumes/") {
            // Confirm it's a read-only DMG mount, not an external SSD or network share.
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            guard values?.volumeIsReadOnly == true else { return }

            // Case 1: running directly from DMG — offer to install
            offerInstall(from: bundlePath, bundleName: bundleName, appName: appName)
        } else {
            // Case 2: running from /Applications — check if DMG is still mounted
            mountedDMGCheckTask = Task {
                await checkForMountedDMG(appName: appName, bundleName: bundleName)
            }
        }
    }

    // MARK: - Case 1: Install from DMG

    private static func offerInstall(from bundlePath: String, bundleName: String, appName: String) {
        guard runAlert(
            message: String(format: NSLocalizedString("Install %@ to Applications?",
                comment: "Alert title: user launched app directly from DMG"),
                appName),
            info: String(format: NSLocalizedString("%@ will copy itself to your Applications folder and relaunch automatically.",
                comment: "Alert body: explains what the install action does"),
                appName),
            buttons: [
                NSLocalizedString("Install", comment: "Confirm install button"),
                NSLocalizedString("Cancel", comment: "Cancel install button"),
            ]
        ) == .alertFirstButtonReturn else { return }

        let destinationURL = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleName)

        // P2: use isDirectory to confirm it's a bundle, not a stray file at that path.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDir), isDir.boolValue {
            guard runAlert(
                message: String(format: NSLocalizedString("Replace existing %@?",
                    comment: "Alert title: an older Muesli.app is already in Applications"),
                    appName),
                info: String(format: NSLocalizedString("An older version of %@ is already in Applications. Replace it?",
                    comment: "Alert body: confirms replacing existing install"),
                    appName),
                buttons: [
                    NSLocalizedString("Replace", comment: "Confirm replace button"),
                    NSLocalizedString("Cancel", comment: "Cancel replace button"),
                ]
            ) == .alertFirstButtonReturn else { return }

            // The existing app is moved to Trash by the background install task below.
        }

        // Derive the DMG volume path from our bundle path (/Volumes/Muesli/Muesli.app → /Volumes/Muesli)
        let volumePath = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().path
        let progressWindow = showInstallProgress(appName: appName)
        let shouldReplaceExisting = isDir.boolValue

        installTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                installFromDMG(
                    bundlePath: bundlePath,
                    destinationPath: destinationURL.path,
                    appName: appName,
                    shouldReplaceExisting: shouldReplaceExisting,
                    volumePath: volumePath
                )
            }.value

            progressWindow.close()

            switch result {
            case .success(let work):
                relaunchInstalledApp(
                    at: destinationURL,
                    volumePath: work.volumePath,
                    sourceDMGPath: work.sourceDMGPath
                )
            case .failure(let error):
                showInstallError(error.localizedDescription)
            }
        }
    }

    nonisolated private static func installFromDMG(
        bundlePath: String,
        destinationPath: String,
        appName: String,
        shouldReplaceExisting: Bool,
        volumePath: String
    ) -> Result<InstallWorkResult, Error> {
        do {
            let destinationURL = URL(fileURLWithPath: destinationPath)
            let installParentURL = destinationURL.deletingLastPathComponent()
            let tempURL = installParentURL.appendingPathComponent(
                ".\(destinationURL.lastPathComponent).installing-\(UUID().uuidString)"
            )
            var shouldRemoveTempCopy = true
            defer {
                if shouldRemoveTempCopy {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            try runProcess(executable: "/usr/bin/ditto", arguments: [bundlePath, tempURL.path])
            try replaceInstalledApp(
                appName: appName,
                tempURL: tempURL,
                destinationURL: destinationURL,
                shouldReplaceExisting: shouldReplaceExisting
            )
            shouldRemoveTempCopy = false

            // Nudge Launch Services so it picks up the freshly-copied bundle immediately,
            // rather than waiting for the next Spotlight re-index or user login.
            try? runProcess(
                executable: "/System/Library/Frameworks/CoreServices.framework"
                    + "/Frameworks/LaunchServices.framework/Support/lsregister",
                arguments: ["-f", destinationPath]
            )

            return .success(InstallWorkResult(
                volumePath: volumePath,
                sourceDMGPath: findSourceDMGPathSync(volumePath: volumePath)
            ))
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func replaceInstalledApp(
        appName: String,
        tempURL: URL,
        destinationURL: URL,
        shouldReplaceExisting: Bool
    ) throws {
        let fileManager = FileManager.default
        guard shouldReplaceExisting else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            return
        }

        let backupURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(destinationURL.deletingPathExtension().lastPathComponent) Previous "
                    + "\(UUID().uuidString).app"
            )

        do {
            try fileManager.moveItem(at: destinationURL, to: backupURL)
        } catch {
            throw NSError(
                domain: "PostInstallChecker",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Couldn't prepare existing \(appName) for replacement: \(error.localizedDescription)",
                ]
            )
        }

        do {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            do {
                if !fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.moveItem(at: backupURL, to: destinationURL)
                }
            } catch {
                throw NSError(
                    domain: "PostInstallChecker",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Couldn't install the new \(appName), and the previous copy could not be restored automatically. It is still available at \(backupURL.path).",
                    ]
                )
            }

            throw NSError(
                domain: "PostInstallChecker",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Couldn't install the new \(appName): \(error.localizedDescription). The previous copy was restored.",
                ]
            )
        }

        do {
            try fileManager.trashItem(at: backupURL, resultingItemURL: nil)
        } catch {
            fputs("[PostInstallChecker] old app cleanup failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func relaunchInstalledApp(
        at destinationURL: URL,
        volumePath: String,
        sourceDMGPath: String?
    ) {
        let cleanupGate = PostInstallCleanupGate()
        let cleanupAndQuit = {
            guard cleanupGate.claim() else { return }
            NSWorkspace.shared.unmountAndEjectDevice(atPath: volumePath)
            if let dmgPath = sourceDMGPath {
                try? FileManager.default.trashItem(
                    at: URL(fileURLWithPath: dmgPath), resultingItemURL: nil)
            }
            ApplicationTermination.request()
        }

        let safetyTimer = PostInstallSafetyTimer()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: destinationURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                safetyTimer.cancel()
                if let error {
                    fputs("[PostInstallChecker] relaunch failed: \(error.localizedDescription)\n", stderr)
                    showInstallError(error.localizedDescription)
                    return
                }
                cleanupAndQuit()
            }
        }

        // Safety net: terminate after 8 s in case openApplication never calls back.
        safetyTimer.schedule(after: .seconds(8), execute: cleanupAndQuit)
    }

    private static func showInstallProgress(appName: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 116),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = String(format: NSLocalizedString("Installing %@",
            comment: "Install progress window title"), appName)
        window.isReleasedWhenClosed = false
        window.level = .floating

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: String(format: NSLocalizedString(
            "Copying %@ to Applications...",
            comment: "Install progress label"), appName))
        label.font = AppFonts.font(size: 13)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        content.addSubview(spinner)
        content.addSubview(label)
        window.contentView = content

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        return window
    }

    private static func showInstallError(_ description: String) {
        fputs("[PostInstallChecker] install failed: \(description)\n", stderr)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Installation failed.",
            comment: "Alert title: install error")
        alert.informativeText = description
        alert.runModal()
    }

    // MARK: - Case 2: Eject mounted DMG

    private static func checkForMountedDMG(appName: String, bundleName: String) async {
        guard let volumeURL = findMountedInstallerVolume(appName: appName, bundleName: bundleName) else { return }
        let volumePath = volumeURL.path
        let sourceDMGPath = await Task.detached(priority: .utility) {
            findSourceDMGPathSync(volumePath: volumePath)
        }.value
        guard let sourceDMGPath else {
            fputs("[PostInstallChecker] mounted installer volume has no source DMG: \(volumePath)\n", stderr)
            return
        }
        guard shouldEjectMountedDMG(appName: appName, sourceDMGPath: sourceDMGPath) else {
            rememberKeptDMGPath(sourceDMGPath)
            return
        }

        // App is installed and the user confirmed cleanup — force-detach via hdiutil
        // so a Finder window holding the volume isn't a blocker.
        let detached = await Task.detached(priority: .utility) {
            hdiutilDetach(mountPoint: volumePath)
        }.value
        if detached {
            await MainActor.run {
                do {
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: sourceDMGPath), resultingItemURL: nil)
                    fputs("[PostInstallChecker] trashed DMG: \(sourceDMGPath)\n", stderr)
                } catch {
                    fputs("[PostInstallChecker] trash failed: \(error.localizedDescription)\n", stderr)
                }
            }
        } else {
            fputs("[PostInstallChecker] failed to eject volume at \(volumePath)\n", stderr)
        }
    }

    private static func shouldEjectMountedDMG(appName: String, sourceDMGPath: String) -> Bool {
        if keptDMGPaths().contains(sourceDMGPath) {
            return false
        }

        return runAlert(
            message: String(format: NSLocalizedString("Eject %@ installer disk?",
                comment: "Alert title: installed app found mounted installer disk"),
                appName),
            info: String(format: NSLocalizedString(
                "%@ is already installed. It can eject the installer disk and move the downloaded DMG to Trash.",
                comment: "Alert body: asks permission to clean up mounted installer disk"),
                appName),
            buttons: [
                NSLocalizedString("Keep", comment: "Keep mounted installer disk button"),
                NSLocalizedString("Eject and Trash DMG", comment: "Confirm installer cleanup button"),
            ]
        ) == .alertSecondButtonReturn
    }

    private static func keptDMGPaths() -> Set<String> {
        let savedPaths = UserDefaults.standard.stringArray(forKey: keptDMGPathsDefaultsKey) ?? []
        let existingPaths = savedPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if existingPaths.count != savedPaths.count {
            UserDefaults.standard.set(existingPaths.sorted(), forKey: keptDMGPathsDefaultsKey)
        }
        return Set(existingPaths)
    }

    private static func rememberKeptDMGPath(_ sourceDMGPath: String) {
        var paths = keptDMGPaths()
        paths.insert(sourceDMGPath)
        UserDefaults.standard.set(Array(paths).sorted(), forKey: keptDMGPathsDefaultsKey)
    }

    // Runs hdiutil detach with -force so a Finder window holding the volume isn't a blocker.
    nonisolated private static func hdiutilDetach(mountPoint: String) -> Bool {
        do {
            try runProcess(
                executable: "/usr/bin/hdiutil",
                arguments: ["detach", mountPoint, "-force", "-quiet"]
            )
            return true
        } catch {
            fputs("[PostInstallChecker] hdiutil detach error: \(error)\n", stderr)
            return false
        }
    }

    // P2: use mountedVolumeURLs instead of contentsOfDirectory("/Volumes") — avoids
    // stale symlinks, firmlinks, and hidden entries that can appear under /Volumes.
    private static func findMountedInstallerVolume(appName: String, bundleName: String) -> URL? {
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) else { return nil }
        return volumes.first { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? ""
            guard name == appName else { return false }
            return FileManager.default.fileExists(
                atPath: url.appendingPathComponent(bundleName).path
            )
        }
    }

    nonisolated private static func findSourceDMGPathSync(volumePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }

        for image in images {
            guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String,
                   mountPoint == volumePath,
                   let imagePath = image["image-path"] as? String {
                    return imagePath
                }
            }
        }
        return nil
    }

    nonisolated private static func runProcess(
        executable: String,
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let processName = URL(fileURLWithPath: executable).lastPathComponent
            let description = errorText.isEmpty
                ? "\(processName) exited with status \(process.terminationStatus)"
                : "\(processName) exited with status \(process.terminationStatus): \(errorText)"
            throw NSError(
                domain: "PostInstallChecker",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: description,
                ]
            )
        }
    }

    // MARK: - Alert helper

    // P3: shared helper to reduce the three identical NSAlert setup blocks to one site.
    @discardableResult
    private static func runAlert(
        message: String,
        info: String,
        buttons: [String]
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}
