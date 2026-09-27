import Darwin
import Foundation
import IOKit

/// One reading of the Mac and the server, for the Activity window and the menu bar (ADR D-060 amendment).
struct SystemSample: Equatable, Sendable {
    /// All cores together, 0–100.
    var cpuPercent: Double?
    /// The server's processes' share of all cores, 0–100.
    var serverCPUPercent: Double?
    /// The GPU's own busy figure, 0–100 (IOKit's "Device Utilization %"), nil where the driver doesn't give it.
    var gpuPercent: Double?
    /// Memory in use, as Activity Monitor counts it (app memory, wired and compressed).
    var memoryUsedBytes: Int64?
    var memoryTotalBytes: Int64?
    /// The server's processes' footprint (on Apple silicon this includes the GPU memory they hold).
    var serverMemoryBytes: Int64?
}

/// Reads CPU, GPU and memory without special rights: Mach's host statistics, IOKit's GPU statistics and the
/// server processes' resource usage. Keeps the previous counters, so each reading is a rate since the last one.
final class SystemMonitor: @unchecked Sendable { // used by one polling loop at a time
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastProcessTime: (cpu: UInt64, wall: UInt64)?
    private let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    func sample(serverPIDs: [pid_t]) -> SystemSample {
        var sample = SystemSample()
        if let ticks = Self.cpuTicks() {
            if let last = lastCPUTicks {
                sample.cpuPercent = Self.percent(busy: ticks.busy &- last.busy, total: ticks.total &- last.total)
            }
            lastCPUTicks = ticks
        }
        sample.gpuPercent = Self.gpuUtilization()
        (sample.memoryUsedBytes, sample.memoryTotalBytes) = Self.memory()

        let pids = serverPIDs.flatMap { [$0] + Self.children(of: $0) }
        if !pids.isEmpty {
            var cpu: UInt64 = 0
            var footprint: Int64 = 0
            for pid in pids {
                if let usage = Self.usage(of: pid) {
                    cpu += usage.cpuNanoseconds
                    footprint += usage.footprint
                }
            }
            sample.serverMemoryBytes = footprint
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if let last = lastProcessTime, now > last.wall, cpu >= last.cpu {
                sample.serverCPUPercent = min(100, Double(cpu - last.cpu) / Double(now - last.wall) / cores * 100)
            }
            lastProcessTime = (cpu, now)
        } else {
            lastProcessTime = nil
        }
        return sample
    }

    // MARK: Readings

    /// Busy share of `total`, 0–100; nil with nothing elapsed.
    static func percent(busy: UInt64, total: UInt64) -> Double? {
        total > 0 ? min(100, Double(busy) / Double(total) * 100) : nil
    }

    /// Every core's ticks added up: busy (user, system, nice) and all.
    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0 ..< Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    /// The GPU's "Device Utilization %" from its IOAccelerator's performance statistics (no root needed).
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
            == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            if let value = stats["Device Utilization %"] as? NSNumber {
                return min(100, max(0, value.doubleValue))
            }
        }
        return nil
    }

    /// Memory in use and in total: app memory (internal pages less purgeable), wired and compressed, as Activity
    /// Monitor's "Memory Used" adds them up.
    static func memory() -> (used: Int64?, total: Int64?) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return (nil, total) }
        let page = Int64(getpagesize())
        let pages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count) + Int64(stats.wire_count)
            + Int64(stats.compressor_page_count)
        return (max(0, pages) * page, total)
    }

    /// A process's CPU time so far and its footprint.
    static func usage(of pid: pid_t) -> (cpuNanoseconds: UInt64, footprint: Int64)? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return (machToNanoseconds(info.ri_user_time + info.ri_system_time), Int64(info.ri_phys_footprint))
    }

    /// llama-server's router runs each model in a child process of its own.
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        return count > 0 ? Array(buffer.prefix(Int(count))).filter { $0 > 0 } : []
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func machToNanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
    }
}
