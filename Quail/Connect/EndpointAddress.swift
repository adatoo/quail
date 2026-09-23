import Darwin
import Foundation

/// The addresses a client should use to reach the endpoint — which isn't
/// always the host it's bound to. `0.0.0.0` (and `::`) mean "every
/// interface": fine to *listen* on, not something to put in a browser or a
/// tool's config.
enum EndpointAddress {
    static func isWildcard(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::" || host == "[::]"
    }

    /// For a client on this Mac: loopback when bound to every interface.
    static func localBase(host: String, port: Int) -> URL? {
        url(host: isWildcard(host) ? "127.0.0.1" : host, port: port)
    }

    /// For a client on another device: this Mac's LAN address when bound
    /// to every interface; `nil` when bound to loopback only (unreachable
    /// from elsewhere) or no LAN address was found.
    static func networkBase(host: String, port: Int, lanAddress: String? = currentLANAddress()) -> URL? {
        if isWildcard(host) {
            return lanAddress.flatMap { url(host: $0, port: port) }
        }
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return nil
        }
        return url(host: host, port: port)
    }

    private static func url(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        return components.url
    }

    /// The first non-loopback IPv4 address on an active interface
    /// (`en0` Wi-Fi/Ethernet first), e.g. "192.168.1.20".
    static func currentLANAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0
            else { continue }
            let address = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            candidates.append((String(cString: entry.pointee.ifa_name), address))
        }
        return (candidates.first { $0.name == "en0" } ?? candidates.first)?.address
    }
}
