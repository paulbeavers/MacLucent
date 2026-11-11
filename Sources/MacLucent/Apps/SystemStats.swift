import Foundation
import Darwin

/// Low-level readers for process and system statistics.
enum ProcStats {
    struct Usage {
        /// Total user + system CPU time, in nanoseconds.
        var cpuNs: UInt64
        /// Physical footprint (what Activity Monitor calls "Memory"), in bytes.
        var footprint: UInt64
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
    }()

    static func usage(_ pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        // rusage CPU times are in Mach absolute-time units (not ns on Apple silicon).
        let ticks = info.ri_user_time &+ info.ri_system_time
        return Usage(cpuNs: ticks &* timebase.numer / timebase.denom, footprint: info.ri_phys_footprint)
    }

    static func children(of pid: pid_t) -> [pid_t] {
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(count) * 2 + 8)
        let n = buf.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(buf.prefix(Int(n))).filter { $0 > 0 } : []
    }

    /// `pid` and all of its descendants.
    static func tree(_ pid: pid_t) -> [pid_t] {
        var out: [pid_t] = [pid]
        var i = 0
        while i < out.count, out.count < 512 {
            out += children(of: out[i])
            i += 1
        }
        return out
    }

    static func startTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }

    static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }
}

enum HostStats {
    /// Cumulative CPU ticks across all cores: (busy, total).
    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks // (user, system, idle, nice)
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Memory in use, computed like Activity Monitor's "Memory Used" (app + wired + compressed).
    static func memoryUsed() -> UInt64? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(info.internal_page_count) &- UInt64(info.purgeable_count)
        return (app + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * page
    }

    static func loadAverage() -> (Double, Double, Double) {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? (l[0], l[1], l[2]) : (0, 0, 0)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func disk() -> (free: Int64, total: Int64)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }
}

/// Samples once per second and keeps a short history for sparklines.
@MainActor
final class StatsSampler {
    struct TerminalSample {
        let title: String
        let directory: String?
        let processes: Int
        let cpu: Double      // % of one core
        let memory: UInt64
    }

    static let historyLength = 60

    private(set) var appCPU: [Double] = []
    private(set) var appMemory: [Double] = []
    private(set) var shellCPU: [Double] = []
    private(set) var shellMemory: [Double] = []
    private(set) var systemCPU: [Double] = []
    private(set) var terminals: [TerminalSample] = []
    private(set) var systemMemoryUsed: UInt64 = 0

    private var lastWall: UInt64 = 0
    private var lastAppCPU: UInt64 = 0
    private var lastCPUByPid: [pid_t: UInt64] = [:]
    private var lastHostTicks: (busy: UInt64, total: UInt64)?
    private var primed = false

    func sample(terminals apps: [TerminalApp]) {
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = Double(now &- lastWall)
        defer { lastWall = now }

        // mac-lucent itself
        let me = ProcStats.usage(getpid())
        if let me {
            if primed { push(&appCPU, Double(me.cpuNs &- lastAppCPU) / wall * 100) }
            lastAppCPU = me.cpuNs
            push(&appMemory, Double(me.footprint))
        }

        // Shells and everything they started
        var seen: [pid_t: UInt64] = [:]
        var samples: [TerminalSample] = []
        var totalCPU = 0.0, totalMem: UInt64 = 0
        for t in apps {
            let root = t.terminal.process?.shellPid ?? 0
            guard root > 0 else { continue }
            var cpu = 0.0, mem: UInt64 = 0, count = 0
            for pid in ProcStats.tree(root) {
                guard let u = ProcStats.usage(pid) else { continue }
                count += 1
                mem += u.footprint
                // Processes that appeared since the last sample started within the interval.
                let prev = lastCPUByPid[pid] ?? (primed ? 0 : u.cpuNs)
                if primed, u.cpuNs >= prev { cpu += Double(u.cpuNs - prev) / wall * 100 }
                seen[pid] = u.cpuNs
            }
            totalCPU += cpu
            totalMem += mem
            samples.append(TerminalSample(title: t.title, directory: t.currentDirectory, processes: count, cpu: cpu, memory: mem))
        }
        lastCPUByPid = seen
        terminals = samples
        if primed { push(&shellCPU, totalCPU) }
        push(&shellMemory, Double(totalMem))

        // System
        if let ticks = HostStats.cpuTicks() {
            if let last = lastHostTicks, ticks.total > last.total {
                push(&systemCPU, Double(ticks.busy - last.busy) / Double(ticks.total - last.total) * 100)
            }
            lastHostTicks = ticks
        }
        systemMemoryUsed = HostStats.memoryUsed() ?? systemMemoryUsed
        primed = true
    }

    private func push(_ series: inout [Double], _ v: Double) {
        series.append(max(0, v))
        if series.count > Self.historyLength { series.removeFirst(series.count - Self.historyLength) }
    }
}
