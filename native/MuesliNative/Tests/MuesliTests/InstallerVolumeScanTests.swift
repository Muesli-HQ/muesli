import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Installer volume scan")
struct InstallerVolumeScanTests {
    @Test("only local, browsable mounts are installer candidates")
    func candidatesSkipNetworkAndHiddenMounts() {
        let mounts = [
            PostInstallChecker.MountedFileSystem(path: "/", isLocal: true, isBrowsable: true),
            PostInstallChecker.MountedFileSystem(path: "/Volumes/Muesli", isLocal: true, isBrowsable: true),
            PostInstallChecker.MountedFileSystem(path: "/Volumes/Time Machine", isLocal: false, isBrowsable: true),
            PostInstallChecker.MountedFileSystem(path: "/System/Volumes/VM", isLocal: true, isBrowsable: false),
        ]
        #expect(PostInstallChecker.installerVolumeCandidates(mounts).map(\.path) == ["/", "/Volumes/Muesli"])
    }

    @Test("the kernel mount table lists the root volume as local, and never a network mount as local")
    func mountTableReadsWithoutContactingServers() {
        let mounts = PostInstallChecker.mountedFileSystems()
        #expect(mounts.contains { $0.path == "/" && $0.isLocal })

        // Cross-check against mount(8): an smbfs, nfs, afpfs or webdav mount must never be marked local.
        let network = Set(Self.networkMountPoints())
        #expect(!mounts.contains { network.contains($0.path) && $0.isLocal })
    }

    private static func networkMountPoints() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").compactMap { line in
            guard ["(smbfs", "(nfs", "(afpfs", "(webdav"].contains(where: { line.contains($0) }),
                  let on = line.range(of: " on "), let paren = line.range(of: " (", range: on.upperBound..<line.endIndex)
            else { return nil }
            return String(line[on.upperBound..<paren.lowerBound])
        }
    }
}
