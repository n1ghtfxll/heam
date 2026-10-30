import AppKit
import CHeam
import Darwin

struct AppShare {
    let name: String
    let bundlePath: String?
    /// Fraction of all CPU and GPU energy (or CPU time) spent since the previous sample.
    let share: Double
    /// CPU plus GPU power in watts, when the kernel reports per-process energy.
    let watts: Double?
    /// How much of this app's energy went to the GPU (0...1).
    let gpuFraction: Double
}

/// Samples per-process CPU and GPU energy and groups helpers/child processes under their app.
///
/// CPU energy comes per process from the kernel. GPU energy only exists as a system total, so it's
/// split between processes by their share of GPU time. Both are joules, so they add up directly.
final class ProcessMonitor: @unchecked Sendable {
    private struct Usage { let energy: UInt64; let cpu: UInt64 }
    private var previous: [pid_t: Usage] = [:]
    private var previousGPU: [pid_t: UInt64] = [:]
    private var labels: [pid_t: (name: String, bundle: String?)] = [:]
    private var lastSample: Date?
    /// Every running process ID per row name, busy or not, so a row's actions reach all of them.
    private(set) var pidsByName: [String: [pid_t]] = [:]

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

        // GPU: this interval's GPU time per pid, and the GPU energy to share out by it.
        let gpuNow = GPUUsage.timeByPID()
        var gpuDeltas: [pid_t: Double] = [:]
        for (pid, time) in gpuNow {
            // A client closing makes the per-pid sum drop; count that interval as zero.
            if let old = previousGPU[pid], time > old { gpuDeltas[pid] = Double(time - old) }
        }
        previousGPU = gpuNow
        let gpuTimeTotal = gpuDeltas.values.reduce(0, +)
        let gpuEnergy = Double(max(0, heam_gpu_energy_nj()))

        let now = Date()
        let elapsed = lastSample.map { now.timeIntervalSince($0) } ?? 0
        lastSample = now
        labels = labels.filter { current[$0.key] != nil }

        // Prefer energy (accounts for P- vs E-cores, and lets GPU energy join in); fall back to CPU time.
        let useEnergy = deltas.contains { $0.energy > 0 }
        let gpuShareable = useEnergy && gpuTimeTotal > 0 && gpuEnergy > 0

        // Processes whose CPU stats we can't read (WindowServer, other users') still show up by GPU.
        if gpuShareable {
            let seen = Set(deltas.map(\.pid))
            for pid in gpuDeltas.keys where !seen.contains(pid) { deltas.append((pid, 0, 0)) }
        }

        var grouped: [String: (bundle: String?, cpu: Double, gpu: Double)] = [:]
        for d in deltas {
            let cpu = Double(useEnergy ? d.energy : d.cpu)
            let gpu = gpuShareable ? gpuEnergy * (gpuDeltas[d.pid] ?? 0) / gpuTimeTotal : 0
            guard cpu + gpu > 0 else { continue }
            let label = label(for: d.pid)
            grouped[label.name, default: (label.bundle, 0, 0)].cpu += cpu
            grouped[label.name]!.gpu += gpu
        }
        var pidMap: [String: [pid_t]] = [:]
        for pid in current.keys { pidMap[label(for: pid).name, default: []].append(pid) }
        pidsByName = pidMap

        let total = grouped.values.reduce(0) { $0 + $1.cpu + $1.gpu }
        guard total > 0 else { return [] }
        return grouped
            .map {
                let cost = $0.value.cpu + $0.value.gpu
                return AppShare(name: $0.key, bundlePath: $0.value.bundle, share: cost / total,
                                watts: useEnergy && elapsed > 0 ? cost / 1e9 / elapsed : nil,
                                gpuFraction: $0.value.gpu / cost)
            }
            .sorted { $0.share > $1.share }
    }

    private func procPath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        proc_pidpath(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
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
        } else if procPath(pid).hasSuffix("/WindowServer") {
            // macOS's compositor: its GPU work is drawing every app's windows to the screen.
            result = ("Screen drawing", nil)
        } else {
            let path = procPath(pid)
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
