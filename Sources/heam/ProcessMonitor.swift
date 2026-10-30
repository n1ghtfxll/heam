import AppKit
import CHeam
import Darwin

struct AppShare {
    let name: String
    let bundlePath: String?
    /// Fraction of all CPU energy (or CPU time) spent since the previous sample.
    let share: Double
    /// CPU power in watts, when the kernel reports per-process energy.
    let watts: Double?
}

/// Samples per-process CPU energy and groups helpers/child processes under their app.
final class ProcessMonitor: @unchecked Sendable {
    private struct Usage { let energy: UInt64; let cpu: UInt64 }
    private var previous: [pid_t: Usage] = [:]
    private var labels: [pid_t: (name: String, bundle: String?)] = [:]
    private var lastSample: Date?

    func sample() -> [AppShare] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))

        var current: [pid_t: Usage] = [:]
        var deltas: [(pid: pid_t, energy: UInt64, cpu: UInt64)] = []
        for pid in pids.prefix(max(0, n)) {
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard rc == 0 else { continue }
            let usage = Usage(energy: info.ri_energy_nj, cpu: info.ri_user_time &+ info.ri_system_time)
            current[pid] = usage
            if let old = previous[pid] {
                deltas.append((pid,
                               usage.energy >= old.energy ? usage.energy - old.energy : 0,
                               usage.cpu >= old.cpu ? usage.cpu - old.cpu : 0))
            }
        }
        previous = current
        let now = Date()
        let elapsed = lastSample.map { now.timeIntervalSince($0) } ?? 0
        lastSample = now
        labels = labels.filter { current[$0.key] != nil }

        // Prefer energy (accounts for P- vs E-cores); fall back to CPU time.
        let totalEnergy = deltas.reduce(0) { $0 + Double($1.energy) }
        let useEnergy = totalEnergy > 0
        let total = useEnergy ? totalEnergy : deltas.reduce(0) { $0 + Double($1.cpu) }
        guard total > 0 else { return [] }

        var grouped: [String: (bundle: String?, cost: Double)] = [:]
        for d in deltas {
            let cost = Double(useEnergy ? d.energy : d.cpu)
            guard cost > 0 else { continue }
            let label = label(for: d.pid)
            grouped[label.name, default: (label.bundle, 0)].cost += cost
        }
        return grouped
            .map {
                AppShare(name: $0.key, bundlePath: $0.value.bundle, share: $0.value.cost / total,
                         watts: useEnergy && elapsed > 0 ? $0.value.cost / 1e9 / elapsed : nil)
            }
            .sorted { $0.share > $1.share }
    }

    private func label(for pid: pid_t) -> (name: String, bundle: String?) {
        if let cached = labels[pid] { return cached }
        let result: (String, String?)
        let owner = heam_responsible_pid(pid)
        if owner != pid, owner > 1 {
            // Credit XPC services and helpers (e.g. WebKit content processes) to the app that spawned them.
            let result = label(for: owner)
            labels[pid] = result
            return result
        }
        if pid == 0 {
            result = ("kernel_task", nil)
        } else {
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = String(cString: pathBuf)
            if let range = path.range(of: ".app/") {
                // Outermost .app bundle, so "Google Chrome Helper" counts as Google Chrome.
                let bundle = String(path[..<range.lowerBound]) + ".app"
                let name = Bundle(path: bundle)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? Bundle(path: bundle)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
                result = (name, bundle)
            } else {
                var nameBuf = [CChar](repeating: 0, count: 256)
                proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                let name = String(cString: nameBuf)
                result = (name.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : name, nil)
            }
        }
        labels[pid] = result
        return result
    }
}
