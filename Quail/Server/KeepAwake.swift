import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while Quail's server runs (ADR D-054): one power assertion, the
/// same kind `caffeinate -i` takes. The display can still turn off, and closing a laptop's lid still
/// sleeps it — that needs `LidSleepGuard`. No password and no install.
@MainActor
final class KeepAwake {
    /// The assertion calls, behind a seam so tests can count them without touching real power state.
    protocol Assertions {
        func create(reason: String) -> IOPMAssertionID?
        func release(_ id: IOPMAssertionID)
    }

    struct System: Assertions {
        func create(reason: String) -> IOPMAssertionID? {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            return result == kIOReturnSuccess ? id : nil
        }

        func release(_ id: IOPMAssertionID) {
            IOPMAssertionRelease(id)
        }
    }

    private let assertions: any Assertions
    private var held: IOPMAssertionID?

    /// What `pmset -g assertions` shows against Quail.
    static let reason = "Quail is serving a local model (Quail > Server > Power)"

    init(assertions: any Assertions = System()) {
        self.assertions = assertions
    }

    var isHolding: Bool {
        held != nil
    }

    /// Takes or releases the assertion; calling it again with the same answer does nothing.
    func update(active: Bool) {
        if active, held == nil {
            held = assertions.create(reason: Self.reason)
        } else if !active, let id = held {
            assertions.release(id)
            held = nil
        }
    }
}
