import AppKit
import HeamShared
import Foundation
import ServiceManagement

/// Sensors bucketed into parts of the Mac people recognise, instead of raw names like "PMU tdie3".
struct SensorGroup: Identifiable {
    let name: String
    let symbol: String
    let sensors: [Sensor]
    var id: String { name }
    var average: Double { sensors.map(\.celsius).reduce(0, +) / Double(sensors.count) }
    var hottest: Double { sensors.map(\.celsius).max() ?? 0 }

    static func classify(_ sensors: [Sensor]) -> [SensorGroup] {
        let kinds: [(name: String, symbol: String, match: (String) -> Bool)] = [
            ("Chip", "cpu", { $0.contains("tdie") }),
            ("Board", "memorychip", { $0.contains("tdev") || $0.contains("tcal") }),
            ("SSD", "internaldrive", { $0.contains("nand") }),
            ("Battery", "battery.75percent", { $0.contains("battery") || $0.contains("gas gauge") }),
        ]
        var remaining = sensors
        var groups: [SensorGroup] = []
        for kind in kinds {
            let hit = remaining.filter { kind.match($0.name.lowercased()) }
            remaining.removeAll { kind.match($0.name.lowercased()) }
            if !hit.isEmpty { groups.append(SensorGroup(name: kind.name, symbol: kind.symbol, sensors: hit)) }
        }
        if !remaining.isEmpty { groups.append(SensorGroup(name: "Other", symbol: "sensor", sensors: remaining)) }
        return groups
    }
}

struct AppImpact: Identifiable {
    let name: String
    let bundlePath: String?
    let share: Double
    /// Degrees above the idle baseline attributed to this app.
    let degrees: Double
    let watts: Double?
    /// Share of this app's energy that went to the GPU (0...1).
    var gpuFraction: Double = 0
    var id: String { name }
}

@MainActor
final class Store: ObservableObject {
    enum Reading: String, CaseIterable, Identifiable {
        case average = "Average", hottest = "Hottest"
        var id: String { rawValue }
    }

    enum FanMode: String, CaseIterable, Identifiable {
        case auto = "Auto", curve = "Curve", manual = "Manual"
        var id: String { rawValue }
    }

    enum Theme: String, CaseIterable, Identifiable {
        case system = "System", light = "Light", dark = "Dark"
        var id: String { rawValue }

        /// Applied app-wide, so the popover, alerts and the update window all follow it.
        @MainActor func apply() {
            switch self {
            case .system: NSApp?.appearance = nil
            case .light: NSApp?.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    enum MenuBarItem: String, CaseIterable, Identifiable {
        case temperature = "Temperature"
        case chip = "Chip Temperature"
        case power = "Power"
        case temperatureAndPower = "Temperature and Power"
        case fan = "Fan Speed"
        var id: String { rawValue }
    }

    @Published private(set) var sensors: [Sensor] = []
    @Published private(set) var history: [Double] = []
    @Published private(set) var impacts: [AppImpact] = []
    @Published private(set) var fans: [Fan] = []
    @Published private(set) var baseline: Double
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var systemWatts: Double?
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var today = DailyHistory.load()
    /// The popover only renders while open; a hidden SwiftUI tree still re-lays out on every update.
    @Published var popoverVisible = false {
        didSet { if popoverVisible { launchAtLogin = SMAppService.mainApp.status == .enabled } }
    }

    @Published var reading: Reading { didSet { save(reading.rawValue, "reading") } }
    @Published var fahrenheit: Bool { didSet { save(fahrenheit, "fahrenheit") } }
    @Published var menuBarItem: MenuBarItem { didSet { save(menuBarItem.rawValue, "menuBarItem") } }
    @Published var theme: Theme {
        didSet {
            save(theme.rawValue, "theme")
            theme.apply()
        }
    }

    @Published private(set) var fanMode: FanMode = .auto
    @Published var fanTargets: [Double] = []
    /// Curve: below `curveStart` macOS runs the fans; they reach full speed at `curveFull`.
    @Published var curveStart: Double { didSet { save(curveStart, "curveStart") } }
    @Published var curveFull: Double { didSet { save(curveFull, "curveFull") } }
    @Published private(set) var curveEngaged = false
    @Published private(set) var fanBusy = false
    @Published private(set) var fanError: String?

    static let interval: TimeInterval = 2
    private static let historyLength = 90          // 3 minutes
    /// The idle baseline creeps up this much per hour when the Mac never gets that cool again.
    private static let baselineRelaxPerHour = 0.5

    let alerts = AlertManager()
    private let monitor = ProcessMonitor()
    private let queue = DispatchQueue(label: "heam.sample", qos: .utility)
    /// Smoothed per-app values so the list doesn't jitter between 2 s samples.
    private var smoothed: [String: (bundle: String?, share: Double, watts: Double?, gpu: Double)] = [:]
    private var smoothedChip: Double?
    private var pidsByName: [String: [pid_t]] = [:]
    private var timer: Timer?
    private var ticks = 0

    init() {
        let defaults = UserDefaults.standard
        reading = Reading(rawValue: defaults.string(forKey: "reading") ?? "") ?? .average
        fahrenheit = defaults.bool(forKey: "fahrenheit")
        menuBarItem = MenuBarItem(rawValue: defaults.string(forKey: "menuBarItem") ?? "") ?? .temperature
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        baseline = defaults.object(forKey: "idleBaseline") as? Double ?? 35
        curveStart = defaults.object(forKey: "curveStart") as? Double ?? 65
        curveFull = defaults.object(forKey: "curveFull") as? Double ?? 95
        // Pick the chart up where the last session left off, so it doesn't start empty.
        if let last = Snapshot.load(), Date().timeIntervalSince(last.date) < 300 {
            history = Array(last.history.suffix(Self.historyLength))
        }
        DispatchQueue.main.async { [theme] in theme.apply() } // NSApp exists once the app has launched
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // A fan mode the user picked survives relaunches; the installed helper means no password prompt.
        if let saved = FanMode(rawValue: defaults.string(forKey: "fanMode") ?? ""), saved != .auto {
            setFanMode(saved, persist: false)
        }
    }

    var average: Double? {
        sensors.isEmpty ? nil : sensors.map(\.celsius).reduce(0, +) / Double(sensors.count)
    }
    var hottest: Double? { sensors.first?.celsius }
    var current: Double? { reading == .average ? average : hottest }
    var groups: [SensorGroup] { SensorGroup.classify(sensors) }
    /// Hottest chip die: what alerts and fan curves watch, since the all-sensor average hides hotspots.
    var chip: Double? { groups.first { $0.name == "Chip" }?.hottest ?? hottest }

    /// Cached: SMAppService.status is a round trip to a system service, too slow to call on every render.
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            try? launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    var menuBarText: String {
        switch menuBarItem {
        case .temperature: format(current)
        case .chip: format(chip)
        case .power: formatWatts(systemWatts)
        case .temperatureAndPower: "\(format(current)) · \(formatWatts(systemWatts))"
        case .fan: fans.first.map { $0.rpm > 0 ? "\(Int($0.rpm))" : "Off" } ?? "--"
        }
    }

    func format(_ celsius: Double?, decimals: Int = 0) -> String {
        guard let c = celsius else { return "--°" }
        let v = fahrenheit ? c * 9 / 5 + 32 : c
        return String(format: "%.\(decimals)f°", v)
    }

    func formatDelta(_ celsius: Double) -> String {
        String(format: "+%.1f°", fahrenheit ? celsius * 9 / 5 : celsius)
    }

    func formatWatts(_ watts: Double?) -> String {
        guard let w = watts else { return "-- W" }
        return w < 10 ? String(format: "%.1f W", w) : String(format: "%.0f W", w)
    }

    func formatEnergy(_ joules: Double) -> String {
        let wh = joules / 3600
        switch wh {
        case ..<0.01: return "<0.01 Wh"
        case ..<1: return String(format: "%.2f Wh", wh)
        case ..<10: return String(format: "%.1f Wh", wh)
        default: return String(format: "%.0f Wh", wh)
        }
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    // MARK: Sampling

    private func tick() {
        let monitor = self.monitor
        queue.async {
            let sensors = Sensors.read()
            let shares = monitor.sample()
            let fans = Fans.read()
            let watts = SMC.number("PSTR")
            let battery = BatteryInfo.read()
            let pids = monitor.pidsByName
            Task { @MainActor in
                self.pidsByName = pids
                if self.battery != battery { self.battery = battery }
                self.apply(sensors: sensors, shares: shares, fans: fans, watts: watts)
            }
        }
        ticks += 1
    }

    private func apply(sensors: [Sensor], shares: [AppShare], fans: [Fan], watts: Double?) {
        self.sensors = sensors
        thermalState = ProcessInfo.processInfo.thermalState
        systemWatts = watts.flatMap { $0 > 0 && $0 < 1000 ? $0 : nil }
        if fans.count != self.fans.count {
            fanTargets = fans.map { $0.minRPM }
        }
        self.fans = fans

        guard let temp = current else { return }
        history.append(temp)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }

        // Idle baseline: the coolest this Mac gets, remembered across launches. It relaxes upward
        // slowly so one cold boot doesn't set it forever, but a steady temperature never becomes "idle".
        // The heat model always uses the all-sensor average, whichever reading the header shows.
        let modelTemp = average ?? temp
        let relax = Self.baselineRelaxPerHour * Self.interval / 3600
        baseline = max(25, min(baseline + relax, modelTemp))
        if ticks % 30 == 0 { save(baseline, "idleBaseline") }

        let headroom = max(0, modelTemp - baseline)
        let fresh = Dictionary(shares.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [String: (bundle: String?, share: Double, watts: Double?, gpu: Double)] = [:]
        for name in Set(fresh.keys).union(smoothed.keys) {
            let old = smoothed[name], new = fresh[name]
            let share = (old?.share ?? 0) * 0.6 + (new?.share ?? 0) * 0.4
            let w: Double? = (old?.watts == nil && new?.watts == nil) ? nil
                : (old?.watts ?? 0) * 0.6 + (new?.watts ?? 0) * 0.4
            let gpu = (old?.gpu ?? 0) * 0.6 + (new?.gpuFraction ?? 0) * 0.4
            if share > 0.002 { next[name] = (new?.bundlePath ?? old?.bundle, share, w, gpu) }
        }
        smoothed = next
        impacts = next
            .sorted { $0.value.share > $1.value.share }
            .prefix(6)
            .map { AppImpact(name: $0.key, bundlePath: $0.value.bundle, share: $0.value.share,
                             degrees: $0.value.share * headroom, watts: $0.value.watts,
                             gpuFraction: $0.value.gpu) }

        today.record(impacts: impacts, systemWatts: systemWatts, temp: temp, chip: chip, seconds: Self.interval)
        if ticks % 15 == 0 { today.save() }
        if ticks % 5 == 0 { writeSnapshot(temp: temp) }

        alerts.evaluate(chip: chip, thermal: thermalState, impacts: impacts, format: { self.format($0) })
        driveFans()
    }

    private func writeSnapshot(temp: Double) {
        Snapshot(date: Date(), temp: temp, chip: chip, watts: systemWatts, fahrenheit: fahrenheit,
                 topApps: impacts.prefix(3).map { .init(name: $0.name, bundlePath: $0.bundlePath, degrees: $0.degrees) },
                 history: history)
            .save()
        Widgets.reload()
    }

    // MARK: Fan control

    /// For `heam --snapshot --demo`: stops sampling and fills the UI with made-up readings that
    /// credit only apps that ship with macOS, so screenshots show nothing from this machine.
    func loadDemo() {
        timer?.invalidate()
        let wave = { (i: Int, amp: Double) in amp * sin(Double(i) * 1.7) }
        sensors = ((1...14).map { Sensor(name: "PMU tdie\($0)", celsius: 63 + wave($0, 4)) }
            + (1...10).map { Sensor(name: "PMU tdev\($0)", celsius: 50 + wave($0, 3)) }
            + [Sensor(name: "NAND CH0 temp", celsius: 44)]
            + (1...6).map { Sensor(name: "gas gauge battery \($0)", celsius: 36 + wave($0, 0.4)) })
            .sorted { $0.celsius > $1.celsius }
        let avg = average ?? 52
        history = (0..<Self.historyLength).map { i in
            let t = Double(i) / Double(Self.historyLength - 1)
            return avg - 7 * (1 - t) * (1 - t) + 0.4 * sin(Double(i) / 4)
        }
        systemWatts = 23.6
        baseline = 38
        thermalState = .nominal
        fans = [Fan(index: 0, rpm: 3120, minRPM: 2317, maxRPM: 6550)]
        battery = BatteryInfo(percent: 82, cycles: 143, ratedCycles: 1000, designCapacity: 6249, fullCapacity: 5880,
                              isCharging: true, onPower: true, fullyCharged: false, watts: 31.2,
                              minutesRemaining: 38, adapterWatts: 96)
        fanTargets = [3120]
        let headroom = avg - baseline
        let demo: [(String, String, Double, Double)] = [
            ("Safari", "/Applications/Safari.app", 6.4, 7.9),
            ("Photos", "/System/Applications/Photos.app", 3.0, 3.6),
            ("Music", "/System/Applications/Music.app", 1.3, 1.4),
            ("Mail", "/System/Applications/Mail.app", 0.7, 0.8),
            ("Maps", "/System/Applications/Maps.app", 0.4, 0.5),
            ("Finder", "/System/Library/CoreServices/Finder.app", 0.2, 0.2),
        ]
        impacts = demo.map { name, path, degrees, watts in
            AppImpact(name: name, bundlePath: path, share: degrees / headroom, degrees: degrees, watts: watts,
                      gpuFraction: ["Photos": 0.72, "Safari": 0.24, "Music": 0.05][name] ?? 0)
        }
        var day = DailyHistory(day: DailyHistory.today())
        day.trackedSeconds = 6 * 3600
        day.peakTemp = 71
        day.peakChip = 88
        day.systemJoules = 92 * 3600
        for (i, (name, path, degrees, watts)) in demo.enumerated() {
            let dayAverage = degrees * [0.55, 0.7, 0.6, 0.5, 0.4, 0.5][i]
            day.apps[name] = DailyHistory.App(
                bundlePath: path, joules: watts * 3 * 3600, secondsOnTop: i == 0 ? 4 * 3600 : 0,
                degreeSeconds: dayAverage * day.trackedSeconds, seconds: [5.5, 1.5, 3, 6, 0.5, 6][i] * 3600,
                peakDegrees: degrees * 2.1)
        }
        today = day
    }

    /// For `heam --snapshot` only: shows a mode's UI without touching the fan helper.
    func previewFanMode(_ mode: FanMode) { fanMode = mode }

    func setFanMode(_ mode: FanMode, persist: Bool = true) {
        fanError = nil
        if persist { save(mode.rawValue, "fanMode") }
        if mode == .auto {
            fanMode = .auto
            curveEngaged = false
            queue.async { FanClient.send("auto") }
            return
        }
        fanBusy = true
        queue.async {
            let ready = FanClient.isCurrent || FanClient.installHelper()
            Task { @MainActor in
                self.fanBusy = false
                guard ready else {
                    self.fanMode = .auto
                    self.save(FanMode.auto.rawValue, "fanMode")
                    self.fanError = "Fan control needs administrator permission."
                    return
                }
                self.fanMode = mode
                if mode == .manual {
                    if self.fanTargets.allSatisfy({ $0 == 0 }) {
                        self.fanTargets = self.fans.map { max($0.minRPM, $0.rpm) }
                    }
                    self.sendTargets()
                } else {
                    self.curveEngaged = false
                    self.driveFans()
                }
            }
        }
    }

    /// The fraction (0...1) of the fan's range the curve wants at `celsius`.
    func curveFraction(at celsius: Double) -> Double {
        min(1, max(0, (celsius - curveStart) / max(curveFull - curveStart, 1)))
    }

    private func driveFans() {
        guard !fanBusy else { return }
        switch fanMode {
        case .auto:
            break
        case .manual:
            // Heartbeat so the helper keeps manual mode (it reverts to auto if the app dies).
            if ticks % 3 == 0 { sendTargets() }
        case .curve:
            guard let c = chip else { return }
            smoothedChip = smoothedChip.map { $0 * 0.7 + c * 0.3 } ?? c
            let t = smoothedChip!
            if t < curveStart - 2 {
                // Cool enough: let macOS run (or stop) the fans.
                if curveEngaged {
                    curveEngaged = false
                    queue.async { FanClient.send("auto") }
                }
            } else if t >= curveStart || curveEngaged {
                curveEngaged = true
                let f = curveFraction(at: t)
                fanTargets = fans.map { $0.minRPM + ($0.maxRPM - $0.minRPM) * f }
                sendTargets()
            }
        }
    }

    func setAllFans(fraction: Double) {
        fanTargets = fans.map { $0.minRPM + ($0.maxRPM - $0.minRPM) * fraction }
        sendTargets()
    }

    func sendTargets() {
        guard fanMode != .auto else { return }
        let command = "set " + fanTargets.map { String(Int($0)) }.joined(separator: ",")
        queue.async {
            let reply = FanClient.send(command)
            Task { @MainActor in
                switch reply {
                case "ok": self.fanError = nil
                case nil:
                    self.fanMode = .auto
                    self.fanError = "Fan helper isn't responding. Pick a mode again to reinstall it."
                default: self.fanError = "This Mac refused the fan speed change."
                }
            }
        }
    }

    func removeFanHelper() {
        fanMode = .auto
        save(FanMode.auto.rawValue, "fanMode")
        queue.async { _ = FanClient.uninstallHelper() }
    }

    func quit() {
        timer?.invalidate()
        today.save()
        // Always give control back to macOS on the way out.
        FanClient.send("auto")
        NSApp.terminate(nil)
    }

    // MARK: Row actions

    /// Never quit from heam: these log you out, blank the screen, or aren't apps at all.
    private static let protectedNames: Set<String> = [
        "kernel_task", "Screen drawing", "WindowServer", "loginwindow", "launchd",
        "SystemUIServer", "ControlCenter", "NotificationCenter", "Dock",
    ]

    func processCount(name: String) -> Int { pidsByName[name]?.count ?? 0 }

    private func runningApps(bundlePath: String?) -> [NSRunningApplication] {
        guard let bundlePath else { return [] }
        let target = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().path == target
        }
    }

    /// Only processes that belong to this user; the rest aren't ours to stop.
    private func userPIDs(name: String) -> [pid_t] {
        (pidsByName[name] ?? []).filter { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == getuid()
        }
    }

    private func isSelf(_ bundlePath: String?) -> Bool {
        bundlePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            == Bundle.main.bundleURL.resolvingSymlinksInPath()
    }

    func canQuit(name: String, bundlePath: String?) -> Bool {
        guard !Self.protectedNames.contains(name) else { return false }
        return isSelf(bundlePath) || !runningApps(bundlePath: bundlePath).isEmpty || !userPIDs(name: name).isEmpty
    }

    func quitProcesses(name: String, bundlePath: String?, force: Bool) {
        guard canQuit(name: name, bundlePath: bundlePath) else { return }
        if isSelf(bundlePath) {
            quit() // hands the fans back to macOS first
            return
        }
        let apps = runningApps(bundlePath: bundlePath)
        if !apps.isEmpty {
            // Like ⌘Q or Force Quit from the Dock; the app's own helpers follow it.
            apps.forEach { _ = force ? $0.forceTerminate() : $0.terminate() }
        } else {
            userPIDs(name: name).forEach { kill($0, force ? SIGKILL : SIGTERM) }
        }
    }

    func revealInFinder(name: String, bundlePath: String?) {
        if let bundlePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundlePath)])
            return
        }
        guard let pid = pidsByName[name]?.first else { return }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: String(cString: buf))])
    }

    func canReveal(name: String, bundlePath: String?) -> Bool {
        bundlePath != nil || pidsByName[name]?.isEmpty == false
    }

    func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
