import Darwin
import Foundation

/// A blocking TCP client for tests that need to say things `URLSession` won't
/// (`Expect: 100-continue`, pipelined requests, malformed heads) and see
/// exactly what comes back, including when the server closes.
final class RawHTTPClient: @unchecked Sendable {
    private let fd: Int32

    init(port: Int, timeoutSeconds: Int = 3) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        close(fd)
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Reads until the text read so far contains `marker` (or the peer closes or
    /// the timeout passes) and returns everything read.
    func read(until marker: String) -> String {
        var text = ""
        while !text.contains(marker) {
            guard let chunk = receive() else { break }
            text += chunk
        }
        return text
    }

    /// Reads until the peer closes the connection. `closed` is false if the
    /// timeout passed first — i.e. the server left the connection open.
    func readToEnd() -> (text: String, closed: Bool) {
        var text = ""
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 {
                return (text, true)
            }
            if count < 0 {
                return (text, false)
            }
            text += String(decoding: buffer.prefix(count), as: UTF8.self)
        }
    }

    private func receive() -> String? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : nil
    }
}

/// A flag a `@Sendable` callback can set and a test can poll.
final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}
