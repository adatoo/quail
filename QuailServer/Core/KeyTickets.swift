import Foundation

/// One-time tickets that let the Quail app sign its own chat page in without putting the API key in a URL
/// (ADR D-042). The app asks for a ticket with the key (`POST /auth/ticket`) and opens the page at
/// `/#ticket=…`; the page trades the ticket for the key once (`POST /auth/exchange`) and forgets the
/// fragment. A ticket is random, lives 30 seconds, works once, and is only ever held in memory.
final class KeyTickets: @unchecked Sendable {
    static let lifetime: TimeInterval = 30
    /// More than a person clicking "Open Chat" could use; an old one is dropped to make room.
    static let limit = 16

    private let now: @Sendable () -> Date
    private let tickets = Locked<[(value: String, expires: Date)]>([])

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func issue() -> String {
        var generator = SystemRandomNumberGenerator() // the system's cryptographic source
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
        let value = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let expires = now().addingTimeInterval(Self.lifetime)
        tickets.withState { list in
            list.removeAll { $0.expires <= now() }
            if list.count >= Self.limit {
                list.removeFirst(list.count - Self.limit + 1)
            }
            list.append((value, expires))
        }
        return value
    }

    /// True once for a live ticket; the ticket is gone afterwards either way.
    func redeem(_ value: String) -> Bool {
        tickets.withState { list in
            list.removeAll { $0.expires <= now() }
            guard let index = list.firstIndex(where: { Self.constantTimeEqual($0.value, value) }) else { return false }
            list.remove(at: index)
            return true
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        for index in 0 ..< max(a.count, b.count) {
            difference |= Int(index < a.count ? a[index] : 0) ^ Int(index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}
