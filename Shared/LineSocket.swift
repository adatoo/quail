import Darwin
import Foundation

/// A connected Unix-domain stream socket that reads and writes whole
/// lines — the transport under `ControlProtocol`. Blocking; callers run it
/// off the main thread.
final class LineSocket: @unchecked Sendable {
    enum SocketError: Error, Equatable, CustomStringConvertible {
        case pathTooLong
        case system(String, Int32)
        case closed

        var description: String {
            switch self {
            case .pathTooLong: "socket path too long"
            case let .system(call, code): "\(call) failed: \(String(cString: strerror(code)))"
            case .closed: "connection closed"
            }
        }
    }

    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// Connects to a listening socket at `path`.
    static func connect(to path: String) throws -> LineSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var addr = try address(for: path)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system("connect", code)
        }
        return LineSocket(fd: fd)
    }

    static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    func writeLine(_ data: Data) throws {
        var line = data
        if line.last != 0x0A {
            line.append(0x0A)
        }
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw SocketError.system("write", errno) }
                offset += written
            }
        }
    }

    /// The next line, without its newline; `nil` at end of stream.
    func readLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer.removeSubrange(buffer.startIndex ... newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count == 0 {
                if buffer.isEmpty {
                    return nil
                }
                defer { buffer.removeAll() }
                return buffer
            }
            guard count > 0 else { throw SocketError.system("read", errno) }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
    }

    /// One request, one response — the whole control exchange.
    static func request(
        _ request: ControlRequest,
        path: String = ControlPaths.socketURL.path
    ) throws -> ControlResponse {
        let socket = try connect(to: path)
        try socket.writeLine(ControlCoding.encodeLine(request))
        guard let line = try socket.readLine() else { throw SocketError.closed }
        return try ControlCoding.decode(ControlResponse.self, line: line)
    }
}
