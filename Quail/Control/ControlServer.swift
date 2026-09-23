import Darwin
import Dispatch
import Foundation
import os

/// The app end of the `quail` CLI's control socket (`ControlProtocol`):
/// accepts connections on a Unix domain socket, reads one request line,
/// answers via `handler`, closes. Created mode 0600 — only this user can
/// connect. Not started when hosting unit tests.
final class ControlServer: @unchecked Sendable {
    private let path: String
    private let handler: @Sendable (ControlRequest) async -> ControlResponse
    private let queue = DispatchQueue(label: "com.datoos.quail.control", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private static let logger = Logger(subsystem: "com.datoos.quail", category: "Control")

    init(
        path: String = ControlPaths.socketURL.path,
        handler: @escaping @Sendable (ControlRequest) async -> ControlResponse
    ) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        stop()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        unlink(path) // a stale socket from a previous run
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LineSocket.SocketError.system("socket", errno) }
        var addr = try LineSocket.address(for: path)
        let previousMask = umask(0o177) // created 0600, not briefly world-accessible
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw LineSocket.SocketError.system("bind/listen", code)
        }
        chmod(path, 0o600)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        let socketPath = path
        Self.logger.notice("control socket listening at \(socketPath, privacy: .public)")
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 {
            unlink(path)
            listenFD = -1
        }
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        let socket = LineSocket(fd: client)
        let handler = handler
        queue.async {
            let request: ControlRequest?
            do {
                request = try socket.readLine().flatMap { try? ControlCoding.decode(ControlRequest.self, line: $0) }
            } catch {
                request = nil
            }
            let done = DispatchSemaphore(value: 0)
            Task {
                let response = if let request {
                    await handler(request)
                } else {
                    ControlResponse.failure("Unreadable request — is the quail command from a different Quail version?")
                }
                try? socket.writeLine(ControlCoding.encodeLine(response))
                done.signal()
            }
            done.wait() // keep `socket` (and its fd) alive until the reply is written
        }
    }
}
