import Foundation
import Security

/// A Unix-domain socket server for the Cotypist input-method helper: one JSON object per line
/// in, one JSON object per line out, one request per connection. The socket lives in the app's
/// support directory (owner-only permissions), so only this user's processes can reach it, and
/// each connection is served only if the process on the other end satisfies `peerRequirement`
/// (the bundled helper's designated requirement). Other processes of this user can't borrow
/// Muesli's Accessibility and screen access through it.
final class CotypistSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable ([String: Any]) async -> [String: Any]

    private let path: String
    private let handler: Handler
    private let peerRequirement: SecRequirement
    private let listenFD: Int32
    private let acceptSource: DispatchSourceRead
    private let queue = DispatchQueue(label: "muesli.cotypist.socket", attributes: .concurrent)
    /// Helper processes already verified, by PID and PID version (a reused PID gets a new version).
    private let verifiedPeers = NSLock()
    private var verified: Set<[Int32]> = []

    init(path: String, peerRequirement: SecRequirement, handler: @escaping Handler) throws {
        self.path = path
        self.peerRequirement = peerRequirement
        self.handler = handler
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        listenFD = fd
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        acceptSource.setEventHandler { [weak self] in self?.acceptConnection() }
        acceptSource.setCancelHandler { close(fd) }
        acceptSource.resume()
    }

    deinit {
        acceptSource.cancel()
        unlink(path)
    }

    private func acceptConnection() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        queue.async { [self, handler] in
            guard isTrustedPeer(client) else {
                fputs("[cotypist] refused a connection from a process that isn't the Cotypist helper\n", stderr)
                close(client)
                return
            }
            guard let request = Self.readLine(client) else { close(client); return }
            Task {
                let response = await handler(request)
                var data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
                data.append(0x0A)
                data.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    /// The connected process is the signed Cotypist helper: its audit token (not its PID, which
    /// can be reused) resolves to running code that satisfies the helper's designated requirement.
    private func isTrustedPeer(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        // PID and PID version: what libbsm's audit_token_to_pid/_pidversion read, without linking it.
        let process = [Int32(bitPattern: token.val.5), Int32(bitPattern: token.val.7)]
        if verifiedPeers.withLock({ verified.contains(process) }) { return true }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], peerRequirement) == errSecSuccess
        else { return false }
        verifiedPeers.withLock { _ = verified.insert(process) }
        return true
    }

    private static func readLine(_ fd: Int32) -> [String: Any]? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < 1 << 20 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if let newline = data.firstIndex(of: 0x0A) { data = data[..<newline]; break }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
