import Darwin
import Foundation
#if canImport(Metal)
    import Metal
#endif

/// Hardware facts about the Mac Quail is running on, per
/// docs/ARCHITECTURE.md §7 ("What Quail reads from the device"). Nothing
/// here is cached — `freeMemoryBytes` in particular changes constantly, so
/// `.current()` re-reads everything on every call. Apple Silicon only, per
/// ARCHITECTURE.md's own non-goals ("Linux or Intel Macs"); every sysctl
/// key read here (`hw.perflevel0/1.physicalcpu`) is Apple-Silicon-only and
/// would simply read as missing on an Intel Mac.
struct DeviceInfo: Sendable, Equatable {
    /// `machdep.cpu.brand_string` — e.g. `"Apple M4 Pro"`. Confirmed on
    /// the machine this parser was written on (a real M4 Pro) that this
    /// is the exact string, matching the keys already seeded in
    /// `Resources/catalog.json`'s `chipBandwidthGBps` table verbatim.
    var chipName: String?
    var performanceCoreCount: Int?
    var efficiencyCoreCount: Int?
    var unifiedMemoryBytes: Int64?
    /// `MTLDevice.recommendedMaxWorkingSetSize` — Apple's own guidance for
    /// how much a GPU workload can use before macOS starts reclaiming
    /// memory elsewhere (roughly 75% of unified memory by default;
    /// `iogpu.wired_limit_mb` raises it). `nil` if no Metal device is
    /// available — expected to happen in some CI/headless environments,
    /// not expected on any real Mac a user runs Quail on.
    var gpuWorkingSetCeilingBytes: Int64?
    /// Free + inactive + purgeable pages, from `host_statistics64` — what's
    /// actually available right now, not the theoretical ceiling above.
    var freeMemoryBytes: Int64?

    /// Reads every fact above fresh from the running machine.
    static func current() -> DeviceInfo {
        var info = DeviceInfo()
        info.chipName = sysctlString("machdep.cpu.brand_string")
        info.performanceCoreCount = sysctlInt32("hw.perflevel0.physicalcpu")
        info.efficiencyCoreCount = sysctlInt32("hw.perflevel1.physicalcpu")
        info.unifiedMemoryBytes = sysctlUInt64("hw.memsize").map(Int64.init)
        info.gpuWorkingSetCeilingBytes = currentGPUWorkingSetCeilingBytes()
        info.freeMemoryBytes = currentFreeMemoryBytes()
        return info
    }

    // MARK: - sysctl

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctlbyname null-terminates; drop the trailing NUL(s) before
        // decoding rather than using the deprecated String(cString:)
        // array overload.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func sysctlInt32(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: - Metal

    private static func currentGPUWorkingSetCeilingBytes() -> Int64? {
        #if canImport(Metal)
            guard let device = MTLCreateSystemDefaultDevice() else { return nil }
            return Int64(device.recommendedMaxWorkingSetSize)
        #else
            return nil
        #endif
    }

    // MARK: - Free memory

    private static func currentFreeMemoryBytes() -> Int64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { statsPointer -> kern_return_t in
            statsPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let freePages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        return Int64(freePages * UInt64(pageSize))
    }
}
