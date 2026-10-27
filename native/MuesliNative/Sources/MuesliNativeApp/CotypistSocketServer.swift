import Foundation

/// A Unix-domain socket server for the Cotypist input-method helper: one JSON object per line
/// in, one JSON object per line out, one request per connection. The socket lives in the app's
/// support directory (owner-only permissions), so only this user's processes can reach it.
final class CotypistSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable ([String: Any]) async -> [String: Any]

    private let path: String
    private let handler: Handler
    private let listenFD: Int32
    private let acceptSource: DispatchSourceRead
    private let queue = DispatchQueue(label: "muesli.cotypist.socket", attributes: .concurrent)

    init(path: String, handler: @escaping Handler) throws {
        self.path = path
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
        queue.async { [handler] in
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
