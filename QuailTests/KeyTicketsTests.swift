import Foundation
import Testing
@testable import QuailServerCore

@Suite("Chat page sign-in tickets")
struct KeyTicketsTests {
    /// A clock the test moves.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        var now: Date {
            lock.withLock { date }
        }

        func advance(_ seconds: TimeInterval) {
            lock.withLock { date += seconds }
        }
    }

    @Test("a ticket works once, and a made-up one never")
    func singleUse() {
        let tickets = KeyTickets()
        let ticket = tickets.issue()
        #expect(ticket.count >= 40 && ticket.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(tickets.issue() != ticket)
        #expect(!tickets.redeem("made-up"))
        #expect(tickets.redeem(ticket))
        #expect(!tickets.redeem(ticket))
    }

    @Test("a ticket expires after 30 seconds")
    func expiry() {
        let clock = Clock()
        let tickets = KeyTickets(now: { clock.now })
        let early = tickets.issue(), late = tickets.issue()
        clock.advance(29)
        #expect(tickets.redeem(early))
        clock.advance(2)
        #expect(!tickets.redeem(late))
    }

    @Test("at most 16 are held; the oldest goes first")
    func limit() {
        let tickets = KeyTickets()
        let issued = (0 ..< 17).map { _ in tickets.issue() }
        #expect(!tickets.redeem(issued[0]))
        #expect(tickets.redeem(issued[1]) && tickets.redeem(issued[16]))
    }
}
