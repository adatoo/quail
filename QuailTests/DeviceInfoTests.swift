import Foundation
import Testing
@testable import Quail

/// `DeviceInfo.current()` reads the real, unpredictable machine the tests
/// happen to run on, so these are sanity checks on invariants that hold
/// for any real Apple Silicon Mac (per docs/ARCHITECTURE.md's own "Apple
/// Silicon only" scope) — not exact expected values. `FitEstimatorTests`
/// is where the actual fit/speed formulas are exercised, against
/// fabricated `DeviceInfo` values.
@Suite("DeviceInfo")
struct DeviceInfoTests {
    @Test("current() reads a real chip name and unified memory size")
    func currentReadsChipNameAndMemory() {
        let info = DeviceInfo.current()

        #expect(info.chipName?.hasPrefix("Apple ") == true)
        #expect((info.unifiedMemoryBytes ?? 0) > 0)
    }

    @Test("current() reads core counts as positive numbers when present")
    func currentReadsPlausibleCoreCounts() {
        let info = DeviceInfo.current()

        // Every real Apple Silicon Mac has at least one performance and
        // one efficiency core; a CI environment that doesn't expose
        // hw.perflevel0/1.physicalcpu at all (nil) is also acceptable —
        // only a reported value of zero or negative would be wrong.
        if let performance = info.performanceCoreCount {
            #expect(performance > 0)
        }
        if let efficiency = info.efficiencyCoreCount {
            #expect(efficiency > 0)
        }
    }

    @Test("current() never reports free memory greater than unified memory")
    func freeMemoryNeverExceedsTotal() {
        let info = DeviceInfo.current()

        if let free = info.freeMemoryBytes, let total = info.unifiedMemoryBytes {
            #expect(free <= total)
        }
    }

    @Test("current() reports a positive GPU working set ceiling when Metal is available")
    func gpuCeilingIsPositiveWhenPresent() {
        let info = DeviceInfo.current()

        // Metal may legitimately be unavailable in a headless CI
        // environment — nil is acceptable, a non-positive number is not.
        if let ceiling = info.gpuWorkingSetCeilingBytes {
            #expect(ceiling > 0)
        }
    }

    @Test("current() reads a model identifier matching sysctl hw.model's own shape")
    func currentReadsModelIdentifier() {
        let info = DeviceInfo.current()

        // "Mac16,11"-shaped: a family name, a comma, a positive number —
        // not asserting the exact model, which varies by test machine.
        if let identifier = info.modelIdentifier {
            #expect(identifier.contains(","))
        }
    }

    @Test("current() reports a positive GPU core count when the IORegistry exposes one")
    func gpuCoreCountIsPositiveWhenPresent() {
        let info = DeviceInfo.current()

        // Absent in a headless CI environment with no GPU accelerator
        // service registered is acceptable; zero or negative isn't.
        if let cores = info.gpuCoreCount {
            #expect(cores > 0)
        }
    }

    @Test("current() reads a non-empty marketing name and OS version string when available")
    func currentReadsMarketingNameAndOSVersion() {
        let info = DeviceInfo.current()

        if let name = info.marketingName {
            #expect(!name.isEmpty)
        }
        #expect(info.osVersion?.isEmpty == false)
    }
}
