import Foundation

/// Keeps a web page in the user's browser from driving the local server (ADR D-036).
///
/// The API key is off by default (D-010), and llama-server answers every cross-origin request
/// with `Access-Control-Allow-Origin: <whatever Origin said>` plus `Allow-Credentials`, so any
/// page you visit could talk to your models. Two rules close that:
///
/// - **Origin.** A browser attaches `Origin` to every cross-origin `fetch` and to every POST.
///   A request carrying one is refused unless the origin is this server's own (same host and
///   port as `Host`, e.g. a UI it serves itself) or was allowed with `--allow-origin`. Refusing
///   is what matters: a "simple" POST needs no preflight and would otherwise still run.
///   Requests with no `Origin` (curl, SDKs, the app) are unaffected.
/// - **Host.** While the server listens on a loopback address, `Host` must name one. DNS
///   rebinding makes a hostile page's own domain resolve to 127.0.0.1, which turns the page
///   into "same origin" as far as the Origin rule can tell; its `Host` is still the hostile name.
///   Not checked when bound to a LAN address, where any name may legitimately reach it.
///
/// An allowed origin gets `Access-Control-Allow-Origin` for exactly that origin (never `*`, never
/// credentials) and its preflight is answered.
struct RequestGuard: Sendable {
    enum Verdict {
        /// Handle the request; `origin` is the allowed cross-origin caller to add CORS headers for.
        case proceed(origin: String?)
        /// Answer with this instead (a refusal, or a preflight).
        case respond(HTTPResponse)
    }

    /// The address the server listens on.
    let bindHost: String
    /// Exact origins (`http://localhost:3000`), or `*` for any (explicit opt-in).
    let allowedOrigins: [String]

    init(bindHost: String, allowedOrigins: [String] = []) {
        self.bindHost = bindHost
        self.allowedOrigins = allowedOrigins
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
    }

    private var bindsToLoopback: Bool {
        Self.isLoopback(bindHost)
    }

    func evaluate(_ request: HTTPRequest) -> Verdict {
        let host = request.header("host")
        if bindsToLoopback, let host, !Self.isLoopback(Self.hostname(of: host)) {
            return .respond(.error(
                421,
                type: "invalid_request_error",
                message: "this server is bound to a loopback address and doesn't answer to the host \"\(host)\""
            ))
        }

        guard let origin = request.header("origin") else {
            // No browser cross-origin context. A bare OPTIONS is still answered.
            return request.method == "OPTIONS" ? .respond(Self.plainOptions()) : .proceed(origin: nil)
        }

        let normalized = origin.lowercased()
        // This server speaks plain HTTP, so only an http origin can be its own.
        let sameOrigin = normalized.hasPrefix("http://")
            && host.map { Self.authority(of: normalized)?.lowercased() == $0.lowercased() } ?? false
        let allowed = allowedOrigins.contains("*") || allowedOrigins.contains(normalized)
        guard sameOrigin || allowed else {
            return .respond(.error(
                403,
                type: "invalid_request_error",
                message: "cross-origin request from \(origin) refused; start quail-server with --allow-origin \(origin) to allow it"
            ))
        }
        // Same-origin needs no CORS headers; an explicitly allowed origin does.
        let corsOrigin: String? = sameOrigin ? nil : origin
        if request.method == "OPTIONS" {
            return .respond(Self.preflight(request, origin: origin))
        }
        return .proceed(origin: corsOrigin)
    }

    func decorate(_ response: HTTPResponse, origin: String?) -> HTTPResponse {
        guard let origin else { return response }
        var result = response
        result.headers.append(("Access-Control-Allow-Origin", origin))
        result.headers.append(("Vary", "Origin"))
        return result
    }

    // MARK: Parsing

    /// `localhost`, `127.x.y.z` and `::1` (with or without the brackets).
    static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name == "::1" {
            return true
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// The host of a `Host` header value: `127.0.0.1:8080` → `127.0.0.1`, `[::1]:8080` → `::1`.
    static func hostname(of hostHeader: String) -> String {
        if hostHeader.hasPrefix("["), let close = hostHeader.firstIndex(of: "]") {
            return String(hostHeader[hostHeader.index(after: hostHeader.startIndex) ..< close])
        }
        return hostHeader.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? hostHeader
    }

    /// `http://localhost:3000` → `localhost:3000`. `nil` for `null` and anything that isn't a plain origin.
    static func authority(of origin: String) -> String? {
        guard let scheme = origin.range(of: "://"),
              ["http", "https"].contains(String(origin[..<scheme.lowerBound]))
        else {
            return nil
        }
        let rest = String(origin[scheme.upperBound...])
        return rest.isEmpty || rest.contains("/") ? nil : rest
    }

    // MARK: Responses

    private static func plainOptions() -> HTTPResponse {
        HTTPResponse(status: 204, headers: [("Allow", "GET, POST, DELETE, OPTIONS")])
    }

    private static func preflight(_ request: HTTPRequest, origin: String) -> HTTPResponse {
        var headers: [(name: String, value: String)] = [
            ("Access-Control-Allow-Origin", origin),
            ("Vary", "Origin"),
            ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS"),
            (
                "Access-Control-Allow-Headers",
                request.header("access-control-request-headers") ?? "authorization, content-type, x-api-key"
            ),
            ("Access-Control-Max-Age", "600"),
        ]
        // Chrome's Private Network Access: a public page reaching a loopback server asks first.
        if request.header("access-control-request-private-network")?.lowercased() == "true" {
            headers.append(("Access-Control-Allow-Private-Network", "true"))
        }
        return HTTPResponse(status: 204, headers: headers)
    }
}
