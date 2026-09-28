import Darwin
import Foundation

/// The addresses a client should use to reach the endpoint — which isn't
/// always the host it's bound to. `0.0.0.0` (and `::`) mean "every
/// interface": fine to *listen* on, not something to put in a browser or a
/// tool's config.
enum EndpointAddress {
    static func isWildcard(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces)
        return host == "0.0.0.0" || host == "::" || host == "[::]"
    }

    /// Who can reach a server listening on a host, as the Server page offers it (ADR D-061).
    enum Reach: String, CaseIterable, Identifiable {
        /// Loopback: only this Mac.
        case thisMac
        /// Every interface: this Mac and other devices on its networks.
        case localNetwork
        /// One particular address, typed in — a LAN or VPN address, say.
        case custom

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .thisMac: "This Mac only"
            case .localNetwork: "Local network"
            case .custom: "Custom"
            }
        }

        /// The host this choice listens on; `nil` for Custom, which keeps whatever address is typed.
        var host: String? {
            switch self {
            case .thisMac: "127.0.0.1"
            case .localNetwork: "0.0.0.0"
            case .custom: nil
            }
        }
    }

    /// Which `Reach` a configured host amounts to. Any other address — one typed in before this choice existed,
    /// too — is Custom, and kept as it is.
    static func reach(of host: String) -> Reach {
        if isLoopback(host) {
            return .thisMac
        }
        return isWildcard(host) ? .localNetwork : .custom
    }

    /// Only this Mac can connect: a loopback address, or `localhost`.
    static func isLoopback(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    /// For a client on this Mac: loopback when bound to every interface.
    static func localBase(host: String, port: Int) -> URL? {
        url(host: isWildcard(host) ? "127.0.0.1" : host.trimmingCharacters(in: .whitespaces), port: port)
    }

    /// For a client on another device: this Mac's LAN address when bound
    /// to every interface; `nil` when bound to loopback only (unreachable
    /// from elsewhere) or no LAN address was found.
    static func networkBase(host: String, port: Int, lanAddress: String? = currentLANAddress()) -> URL? {
        if isWildcard(host) {
            return lanAddress.flatMap { url(host: $0, port: port) }
        }
        if isLoopback(host) {
            return nil
        }
        return url(host: host.trimmingCharacters(in: .whitespaces), port: port)
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
