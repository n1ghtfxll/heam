import Foundation

struct Fan: Identifiable, Hashable {
    let index: Int
    let rpm: Double
    let minRPM: Double
    let maxRPM: Double
    var id: Int { index }
    var name: String { "Fan \(index + 1)" }
}

enum Fans {
    static func read() -> [Fan] {
        let count = Int(SMC.number("FNum") ?? 0)
        return (0..<count).compactMap { i in
            guard let rpm = SMC.number("F\(i)Ac") else { return nil }
            let lo = SMC.number("F\(i)Mn") ?? 0
            let hi = SMC.number("F\(i)Mx") ?? max(lo, 6000)
            return Fan(index: i, rpm: max(0, rpm), minRPM: lo, maxRPM: hi)
        }
    }

    /// Mode key spelling differs between Mac generations.
    private static func modeKey(_ i: Int) -> String? {
        ["F\(i)Md", "F\(i)md"].first(where: SMC.exists)
    }

    // The writes below require root, so they only run inside the fan daemon.

    static func setManual(_ targets: [Double]) -> Bool {
        let fans = read()
        // Apple Silicon: ask thermalmonitord to hand over control.
        if SMC.exists("Ftst") { SMC.write("Ftst", 1) }
        var ok = true
        for fan in fans where fan.index < targets.count {
            guard let md = modeKey(fan.index) else { ok = false; continue }
            // Handover can take a few seconds after Ftst is set.
            var switched = false
            for _ in 0..<50 {
                if SMC.write(md, 1) { switched = true; break }
                usleep(100_000)
            }
            let rpm = min(max(targets[fan.index], fan.minRPM), fan.maxRPM)
            ok = switched && SMC.write("F\(fan.index)Tg", rpm) && ok
        }
        return ok
    }

    /// Updates targets on fans already in manual mode, skipping the slow handover.
    static func setTargets(_ targets: [Double]) -> Bool {
        let fans = read()
        if fans.contains(where: { f in modeKey(f.index).flatMap(SMC.number) == 0 }) {
            return setManual(targets)
        }
        var ok = true
        for fan in fans where fan.index < targets.count {
            ok = SMC.write("F\(fan.index)Tg", min(max(targets[fan.index], fan.minRPM), fan.maxRPM)) && ok
        }
        return ok
    }

    static func setAutomatic() {
        for fan in read() {
            if let md = modeKey(fan.index) { SMC.write(md, 0) }
        }
        if SMC.exists("Ftst") { SMC.write("Ftst", 0) }
    }
}
