import Darwin
import Foundation

/*
 * Host-side conditions, for the diagnostic overlay.
 *
 * This exists because of how often a measurement of the *guest* turns out to
 * be a measurement of the host. Three times in one day: a fanless Mac
 * throttling until an unchanged build lost half its frame rate, a leftover
 * benchmark process quietly competing for cores, and a disk utility scanning
 * in the background while the emulator was being judged. Each cost real time
 * to unpick, and each would have been obvious from these numbers.
 *
 * So the point is not completeness. It is answering one question at a
 * glance: can I trust what I am seeing right now?
 */
struct HostSample {
    /// Percent of one core, as Activity Monitor reports it.
    var qemuCPU: Double
    /// Percent of *all* cores, system-wide, including us.
    var hostBusy: Double
    var load1: Double
    var cores: Int
    var thermal: ProcessInfo.ThermalState

    /// True when the host is loaded enough that guest numbers are suspect.
    ///
    /// The test is "someone other than us is busy", not "the machine is
    /// busy": the emulator saturating a core is the normal, healthy case and
    /// must not raise a warning, or the warning gets ignored.
    var contended: Bool {
        hostBusy - (qemuCPU / Double(max(cores, 1))) > 25 ||
            load1 > Double(cores) * 1.5
    }

    var thermalText: String {
        switch thermal {
        case .nominal:  return "ok"
        case .fair:     return "fair"
        case .serious:  return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "?"
        }
    }
}

@MainActor
final class HostStats {
    private var lastProcNanos: UInt64?
    private var lastProcWall: Double?
    private var lastTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?

    private let cores = ProcessInfo.processInfo.activeProcessorCount

    func sample(qemuPID: pid_t?) -> HostSample {
        HostSample(qemuCPU: processCPU(qemuPID),
                   hostBusy: systemBusy(),
                   load1: loadAverage(),
                   cores: cores,
                   thermal: ProcessInfo.processInfo.thermalState)
    }

    /// CPU time the emulator has used since the last sample, as a percentage
    /// of one core. Rates, not totals: a total climbs forever and says
    /// nothing about now.
    private func processCPU(_ pid: pid_t?) -> Double {
        guard let pid, pid > 0 else {
            lastProcNanos = nil
            return 0
        }
        var info = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard rc == 0 else { return 0 }

        let nanos = info.ri_user_time + info.ri_system_time
        let wall = ProcessInfo.processInfo.systemUptime
        defer { lastProcNanos = nanos; lastProcWall = wall }
        guard let prev = lastProcNanos, let prevWall = lastProcWall,
              wall > prevWall, nanos >= prev else {
            return 0
        }
        return Double(nanos - prev) / 1e9 / (wall - prevWall) * 100
    }

    /// Percent of all cores busy, system-wide, from the difference in tick
    /// counters since the last sample.
    private func systemBusy() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let rc = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return 0 }

        let cur = (user: UInt64(info.cpu_ticks.0), sys: UInt64(info.cpu_ticks.1),
                   idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
        defer { lastTicks = cur }
        guard let prev = lastTicks else { return 0 }

        let busy = (cur.user - prev.user) + (cur.sys - prev.sys) + (cur.nice - prev.nice)
        let total = busy + (cur.idle - prev.idle)
        return total > 0 ? Double(busy) / Double(total) * 100 : 0
    }

    private func loadAverage() -> Double {
        var avg = [Double](repeating: 0, count: 3)
        return getloadavg(&avg, 3) > 0 ? avg[0] : 0
    }
}
