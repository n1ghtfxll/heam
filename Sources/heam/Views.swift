import Charts
import SwiftUI

func heatColor(_ celsius: Double) -> Color {
    switch celsius {
    case ..<55: .green
    case ..<70: .yellow
    case ..<85: .orange
    default: .red
    }
}

/// Critically damped default; nothing in the popover is flicked, so nothing overshoots.
let calmSpring = Animation.spring(response: 0.4, dampingFraction: 1)

// MARK: - Layout primitives

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set by `heam --snapshot`: ImageRenderer can't draw AppKit-backed controls, so a few views
    /// draw a look-alike instead. The real app always uses the native control.
    var heamSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

/// A small native segmented control.
struct Segmented<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    @Environment(\.heamSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].0)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(options[i].1 == selection ? Color.primary.opacity(0.2) : .clear,
                                    in: .rect(cornerRadius: 5, style: .continuous))
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 7, style: .continuous))
        } else {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].0).tag(options[i].1) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// A Control Center–style module: one quiet fill, continuous corners, hairline edge.
struct Module<Content: View>: View {
    var title: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    accessory
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

struct PopoverView: View {
    @ObservedObject var store: Store
    @Environment(\.heamSnapshot) private var snapshot

    var body: some View {
        Group {
            if store.popoverVisible {
                VStack(spacing: 8) {
                    HeaderModule(store: store)
                    SensorTiles(store: store)
                    ImpactModule(store: store)
                    FanModule(store: store)
                    Footer(store: store)
                }
            } else {
                // Closed: keep nothing alive that would re-lay out every two seconds.
                Color.clear.frame(height: 1)
            }
        }
        .padding(10)
        .frame(width: 360)
        .background { if !snapshot { WindowVisibilityReader { store.popoverVisible = $0 } } }
    }
}

/// Reports whether the hosting window is actually on screen. MenuBarExtra builds its window up front
/// and never sends onDisappear, so onAppear alone would keep the popover rendering forever.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification]
            observers = names.map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                }
            }
            report()
        }

        private func report() {
            let visible = (window?.isVisible ?? false) && (window?.occlusionState.contains(.visible) ?? false)
            guard visible != last else { return }
            last = visible
            let callback = onChange
            DispatchQueue.main.async { callback(visible) }
        }
    }
}

// MARK: - Header

struct HeaderModule: View {
    @ObservedObject var store: Store

    var body: some View {
        Module {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.reading == .average ? "AVERAGE OF \(store.sensors.count) SENSORS" : "HOTTEST SENSOR")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.secondary)
                    Text(store.format(store.current, decimals: 1))
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .tracking(-1.2) // large display text reads better tightened
                        .monospacedDigit()
                        .foregroundStyle(heatColor(store.current ?? 0).gradient)
                        .contentTransition(.numericText(value: store.current ?? 0))
                        .animation(calmSpring, value: store.current)
                    HStack(spacing: 6) {
                        ThermalPill(state: store.thermalState)
                        if let w = store.systemWatts {
                            Label(store.formatWatts(w), systemImage: "bolt.fill")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.07), in: .capsule)
                                .contentTransition(.numericText(value: w))
                                .animation(calmSpring, value: w)
                                .help("Whole-system power draw")
                        }
                    }
                }
                Spacer()
                Segmented(options: Store.Reading.allCases.map { ($0.rawValue, $0) }, selection: $store.reading)
            }
            HistoryChart(values: store.history, format: { store.format($0) })
        }
    }
}

/// macOS's own thermal pressure, which is what actually decides when the Mac slows down.
struct ThermalPill: View {
    let state: ProcessInfo.ThermalState

    private var info: (label: String, symbol: String, color: Color) {
        switch state {
        case .nominal: ("No throttling", "checkmark.circle.fill", .green)
        case .fair: ("Warm", "thermometer.medium", .yellow)
        case .serious: ("Throttling", "tortoise.fill", .orange)
        case .critical: ("Critical", "exclamationmark.triangle.fill", .red)
        @unknown default: ("Unknown", "questionmark.circle", .secondary)
        }
    }

    var body: some View {
        Label(info.label, systemImage: info.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(info.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(info.color.opacity(0.14), in: .capsule)
            .help("macOS thermal pressure. Above \"Warm\", the system starts slowing the chip down to cool it.")
    }
}

struct HistoryChart: View {
    let values: [Double]
    let format: (Double) -> String

    var body: some View {
        let tint = heatColor(values.last ?? 0)
        let offset = 0
        HStack(alignment: .center, spacing: 8) {
            Chart(Array(values.enumerated()), id: \.offset) { point in
                AreaMark(x: .value("t", point.offset + offset), y: .value("°", point.element))
                    .foregroundStyle(.linearGradient(colors: [tint.opacity(0.3), tint.opacity(0)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", point.offset + offset), y: .value("°", point.element))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...max(values.count - 1, 1))
            .chartYScale(domain: .automatic(includesZero: false))
            VStack(alignment: .trailing) {
                Text(format(values.max() ?? 0))
                Spacer()
                Text("3 min").foregroundStyle(.tertiary)
                Spacer()
                Text(format(values.min() ?? 0))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(height: 52)
    }
}

// MARK: - Sensor tiles

struct SensorTiles: View {
    @ObservedObject var store: Store
    @State private var open: String?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(store.groups) { group in
                Button {
                    open = group.name
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: group.name == "Battery" ? batterySymbol : group.symbol)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            if group.name == "Battery", let battery = store.battery {
                                Spacer(minLength: 0)
                                Text("\(battery.percent)%")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(store.format(group.average))
                            .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(heatColor(group.average))
                        Text(group.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(open == group.name ? 0.12 : 0.05),
                                in: .rect(cornerRadius: 12, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(PressableStyle())
                // A popover anchored to the tile, so the panel never resizes.
                .popover(isPresented: Binding(get: { open == group.name }, set: { if !$0 { open = nil } }),
                         arrowEdge: .bottom) {
                    SensorList(store: store, group: group)
                }
            }
        }
    }
}

extension SensorTiles {
    /// The battery glyph fills with the real charge and shows a bolt while charging.
    var batterySymbol: String {
        guard let b = store.battery else { return "battery.75percent" }
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

struct SensorList: View {
    @ObservedObject var store: Store
    let group: SensorGroup

    var body: some View {
        // Re-read the group so values stay live while the popover is open.
        let live = store.groups.first { $0.name == group.name } ?? group
        VStack(alignment: .leading, spacing: 8) {
            if live.name == "Battery", let battery = store.battery {
                BatteryDetails(battery: battery, temperature: store.format(live.average, decimals: 1))
                Divider()
            }
            HStack {
                if live.name == "Battery", store.battery != nil {
                    // The details above already carry the title.
                    Text("Sensors").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                } else {
                    Label(live.name, systemImage: live.symbol).font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Text("hottest \(store.format(live.hottest, decimals: 1))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(live.sensors) { s in
                        HStack {
                            Text(s.name).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(store.format(s.celsius, decimals: 1))
                                .monospacedDigit()
                                .foregroundStyle(heatColor(s.celsius))
                        }
                        .font(.system(size: 11))
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 260)
    }
}

/// Feedback on press, not release.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}

// MARK: - Apps

struct ImpactModule: View {
    @ObservedObject var store: Store
    @State var span: Span = .now

    enum Span: String, CaseIterable { case now = "Now", today = "Today" }
    private static let slots = 6

    var body: some View {
        Module(title: span == .now ? "Heating your Mac" : "Heat today",
               accessory: AnyView(
                   Segmented(options: Span.allCases.map { ($0.rawValue, $0) }, selection: $span))) {
            // Both views fill the same number of fixed-height slots, so switching never resizes the panel.
            VStack(spacing: 2) {
                ForEach(0..<Self.slots, id: \.self) { i in
                    if let row = rows[safe: i] {
                        ImpactRow(name: row.name, bundlePath: row.bundlePath, relative: row.relative,
                                  value: row.value, detail: row.detail, gpuHeavy: row.gpuHeavy)
                            .contextMenu { RowMenu(store: store, name: row.name, bundlePath: row.bundlePath) }
                    } else {
                        Color.clear.frame(height: ImpactRow.height)
                    }
                }
            }
            .overlay {
                if rows.isEmpty {
                    Text(span == .now ? "Measuring…" : "Nothing recorded yet today")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text(footnote)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(span == .now
                      ? "Idle is the coolest this Mac has been recently. Degrees above it are split between apps by their share of CPU and GPU energy."
                      : "Degrees each app added, averaged over everything measured today. Hover a row for its peak.")
        }
    }

    private struct Row {
        let name: String, bundlePath: String?, relative: Double, value: String, detail: String
        var gpuHeavy = false
    }

    private var rows: [Row] {
        switch span {
        case .now:
            let top = max(store.impacts.first?.degrees ?? 0, 0.05)
            return store.impacts.map { app in
                Row(name: app.name, bundlePath: app.bundlePath, relative: app.degrees / top,
                    value: store.formatDelta(app.degrees),
                    detail: [app.watts.map { store.formatWatts($0) },
                             app.gpuFraction >= 0.05 ? String(format: "%.0f%% GPU", app.gpuFraction * 100) : nil,
                             String(format: "%.0f%% of energy", app.share * 100)].compactMap { $0 }.joined(separator: ", "),
                    gpuHeavy: app.gpuFraction >= 0.5)
            }
        case .today:
            let ranked = store.today.ranked.prefix(Self.slots)
            let day = store.today
            let top = max(ranked.first.map { day.dayAverage($0.app) } ?? 0, 0.01)
            return ranked.map { item in
                let avg = day.dayAverage(item.app)
                return Row(name: item.name, bundlePath: item.app.bundlePath, relative: avg / top,
                           value: store.formatDelta(avg),
                           detail: "peak \(store.formatDelta(item.app.peakDegrees)), ran \(Int(item.app.seconds / 60)) min")
            }
        }
    }

    private var footnote: String {
        switch span {
        case .now:
            "Degrees above idle (\(store.format(store.baseline))), split by CPU and GPU energy"
        case .today:
            "Peak \(store.format(store.today.peakTemp)), chip \(store.format(store.today.peakChip)), \(store.formatEnergy(store.today.systemJoules)) used"
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct ImpactRow: View {
    static let height: CGFloat = 34
    let name: String
    let bundlePath: String?
    let relative: Double
    let value: String
    /// Shown in place of `value` on hover.
    let detail: String
    /// Most of this app's heat comes from the GPU (games, video, 3D).
    var gpuHeavy = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(bundlePath: bundlePath)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.system(size: 13)).lineLimit(1)
                    if gpuHeavy {
                        Text("GPU")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 3, style: .continuous))
                            .help("Most of this app's heat comes from the GPU")
                    }
                    Spacer()
                    Text(hovering ? detail : value)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(hovering ? .secondary : .primary)
                        .contentTransition(.numericText())
                }
                GeometryReader { geo in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.orange.gradient)
                                .frame(width: max(4, geo.size.width * relative))
                        }
                }
                .frame(height: 4)
                .animation(calmSpring, value: relative)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background(Color.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct AppIcon: View {
    let bundlePath: String?
    private static var cache: [String: NSImage?] = [:]

    var body: some View {
        Group {
            if let path = bundlePath, let icon = Self.icon(path) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: bundlePath == nil ? "terminal.fill" : "app.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 5, style: .continuous))
            }
        }
        .frame(width: 22, height: 22)
    }

    /// nil when the bundle declares no icon, where Finder would draw a blank square.
    private static func icon(_ path: String) -> NSImage? {
        if let hit = cache[path] { return hit }
        let info = Bundle(path: path)?.infoDictionary ?? [:]
        let hasIcon = ["CFBundleIconFile", "CFBundleIconName", "CFBundleIcons"].contains { info[$0] != nil }
        // Resolve symlinks (Safari lives in a cryptex), or Finder draws an alias arrow on the icon.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let image = hasIcon ? NSWorkspace.shared.icon(forFile: resolved) : nil
        cache[path] = image
        return image
    }
}

// MARK: - Fans

struct FanModule: View {
    @ObservedObject var store: Store

    var body: some View {
        Module(title: "Fans", accessory: AnyView(accessory)) {
            if store.fans.isEmpty {
                Text("No fans. This Mac is passively cooled.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(store.fans) { fan in
                FanRow(fan: fan)
            }
            if !store.fans.isEmpty {
                // Same height in every mode: a resize makes the menu bar window jump.
                controls
                    .frame(maxWidth: .infinity, minHeight: Self.controlsHeight, maxHeight: Self.controlsHeight,
                           alignment: .topLeading)
            }
        }
    }

    private static let controlsHeight: CGFloat = 54
    @State private var showCurve = false
    @State private var manualFraction = 0.0

    @ViewBuilder private var controls: some View {
        if let error = store.fanError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch store.fanMode {
            case .auto:
                Text("macOS is controlling the fans.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .curve:
                HStack(alignment: .top, spacing: 10) {
                    Text(store.curveEngaged
                         ? "Following the curve at \(Int(store.curveFraction(at: store.chip ?? 0) * 100))%. Full speed at \(store.format(store.curveFull))."
                         : "Ramps up from \(store.format(store.curveStart)), full speed at \(store.format(store.curveFull)). macOS runs the fans below that.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Edit Curve…") { showCurve = true }
                        .controlSize(.small)
                        .popover(isPresented: $showCurve, arrowEdge: .bottom) {
                            CurveEditor(store: store).padding(14).frame(width: 320)
                        }
                }
            case .manual:
                VStack(spacing: 8) {
                    Slider(value: $manualFraction, in: 0...1) {
                        Text("Fan speed")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise").font(.system(size: 10))
                    } maximumValueLabel: {
                        Image(systemName: "hare").font(.system(size: 10))
                    } onEditingChanged: { editing in
                        if !editing { store.setAllFans(fraction: manualFraction) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    HStack(spacing: 6) {
                        PresetButton(title: "Quiet", symbol: "leaf") { setManual(0) }
                        PresetButton(title: "Balanced", symbol: "circle.lefthalf.filled") { setManual(0.5) }
                        PresetButton(title: "Max", symbol: "wind") { setManual(1) }
                    }
                }
                .onAppear { manualFraction = currentFraction }
            }
        }
    }

    private func setManual(_ fraction: Double) {
        manualFraction = fraction
        store.setAllFans(fraction: fraction)
    }

    /// Where the first fan's target sits in its range, to start the shared slider there.
    private var currentFraction: Double {
        guard let fan = store.fans.first, let target = store.fanTargets.first else { return 0 }
        return min(1, max(0, (target - fan.minRPM) / max(fan.maxRPM - fan.minRPM, 1)))
    }

    @ViewBuilder private var accessory: some View {
        if !store.fans.isEmpty {
            HStack(spacing: 6) {
                if store.fanBusy { ProgressView().controlSize(.mini) }
                Segmented(options: Store.FanMode.allCases.map { ($0.rawValue, $0) },
                          selection: Binding(get: { store.fanMode }, set: { store.setFanMode($0) }))
                    .disabled(store.fanBusy)
            }
        }
    }
}

/// Fan speed as a function of chip temperature, with the live reading marked on it.
struct CurveEditor: View {
    @ObservedObject var store: Store
    private let domain = 40.0...110.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(points, id: \.0) { t, f in
                    AreaMark(x: .value("°", t), y: .value("%", f * 100))
                        .foregroundStyle(.linearGradient(colors: [.teal.opacity(0.3), .teal.opacity(0)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("°", t), y: .value("%", f * 100))
                        .foregroundStyle(.teal)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                if let c = store.chip {
                    RuleMark(x: .value("now", min(max(c, domain.lowerBound), domain.upperBound)))
                        .foregroundStyle(heatColor(c))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text(store.format(c)).font(.system(size: 9, weight: .semibold)).foregroundStyle(heatColor(c))
                        }
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: [40, 60, 80, 100]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(store.format(v.as(Double.self))) }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
                }
            }
            .frame(height: 90)
            .padding(.top, 12) // room for the live-temperature label

            CurveSlider(label: "Ramp from", value: $store.curveStart, range: 45...85, format: store.format)
            CurveSlider(label: "Full speed at", value: $store.curveFull,
                        range: (store.curveStart + 5)...105, format: store.format)

            Text(store.curveEngaged
                 ? "Following the curve at \(Int(store.curveFraction(at: store.chip ?? 0) * 100))%."
                 : "Below \(store.format(store.curveStart)), macOS runs the fans and may turn them off.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .onChange(of: store.curveStart) { _, start in
            if store.curveFull < start + 5 { store.curveFull = start + 5 }
        }
    }

    /// Flat below the ramp (macOS's minimum), straight ramp, flat at 100%.
    private var points: [(Double, Double)] {
        [(domain.lowerBound, 0), (store.curveStart, 0), (store.curveFull, 1), (domain.upperBound, 1)]
    }
}

struct CurveSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double?, Int) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Slider(value: $value, in: range, step: 1).controlSize(.mini)
            Text(format(value, 0)).font(.system(size: 11, weight: .medium).monospacedDigit()).frame(width: 34, alignment: .trailing)
        }
    }
}

struct FanRow: View {
    let fan: Fan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let span = max(fan.maxRPM - fan.minRPM, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Spin speed follows the real RPM.
                Image(systemName: "fan.fill")
                    .foregroundStyle(fan.rpm > 0 ? .primary : .tertiary)
                    .symbolEffect(.rotate.byLayer,
                                  options: .repeat(.continuous).speed(max(0.3, fan.rpm / 2500)),
                                  isActive: fan.rpm > 0 && !reduceMotion)
                Text(fan.name).font(.system(size: 13))
                Spacer()
                Text(fan.rpm > 0 ? "\(Int(fan.rpm)) rpm" : "Off")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: fan.rpm))
                    .animation(calmSpring, value: fan.rpm)
            }
            GeometryReader { geo in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.teal.gradient)
                            .frame(width: geo.size.width * min(1, max(0, (fan.rpm - fan.minRPM) / span)))
                    }
            }
            .frame(height: 4)
            .animation(calmSpring, value: fan.rpm)
        }
    }
}

struct PresetButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.07), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Footer

struct Footer: View {
    @ObservedObject var store: Store
    @ObservedObject var alerts: AlertManager
    @Environment(\.heamSnapshot) private var snapshot

    init(store: Store) {
        self.store = store
        self.alerts = store.alerts
    }

    var body: some View {
        if snapshot {
            HStack {
                Image(systemName: "gearshape")
                versionLabel
                Spacer()
                Text("Quit heam")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.top, 2)
        } else {
            menuRow
        }
    }

    /// The running build's version, one step dimmer than the Quit button.
    @ViewBuilder private var versionLabel: some View {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            Text("v\(version)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .help("heam \(version)")
        }
    }

    private var menuRow: some View {
        HStack {
            Menu {
                Picker("Menu Bar Shows", selection: $store.menuBarItem) {
                    ForEach(Store.MenuBarItem.allCases) { Text($0.rawValue).tag($0) }
                }
                Menu("Alerts") {
                    if alerts.permissionDenied {
                        Text("Notifications are off for heam in System Settings")
                    }
                    Toggle("When the chip runs hot", isOn: $alerts.hotEnabled)
                    Picker("Above", selection: $alerts.threshold) {
                        ForEach(AlertManager.thresholds, id: \.self) { Text(store.format($0)).tag($0) }
                    }
                    .disabled(!alerts.hotEnabled)
                    Picker("For", selection: $alerts.duration) {
                        ForEach(AlertManager.durations, id: \.self) { Text(AlertManager.describe($0)).tag($0) }
                    }
                    .disabled(!alerts.hotEnabled)
                    Divider()
                    Toggle("When macOS throttles", isOn: $alerts.throttleEnabled)
                    Divider()
                    Button("Send Test Alert") {
                        alerts.sendTest(chip: store.chip, impacts: store.impacts, format: { store.format($0) })
                    }
                }
                Picker("Appearance", selection: $store.theme) {
                    ForEach(Store.Theme.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Toggle("Show in Fahrenheit", isOn: $store.fahrenheit)
                Toggle("Open at Login", isOn: $store.launchAtLogin)
                Divider()
                if let updater = Updater.shared {
                    UpdateMenuItems(updater: updater)
                    Divider()
                }
                Button("Remove Fan Helper…") { store.removeFanHelper() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            versionLabel
            Spacer()
            Button("Quit heam") { store.quit() }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}

struct UpdateMenuItems: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
        Toggle("Check for Updates Automatically", isOn: Binding(get: { updater.checksAutomatically },
                                                               set: { updater.checksAutomatically = $0 }))
    }
}

struct BatteryDetails: View {
    let battery: BatteryInfo
    let temperature: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(battery.percent)%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .tracking(-0.5)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(chargeColor.gradient)
                            .frame(width: max(4, geo.size.width * Double(battery.percent) / 100))
                    }
            }
            .frame(height: 5)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                if let health = battery.health {
                    row("Health", String(format: "%.0f%%", health * 100) + (health < 0.8 ? ", service recommended" : ""),
                        help: "How much charge the battery holds now compared with when it was new.")
                }
                row("Cycles", battery.ratedCycles.map { "\(battery.cycles) of \($0.formatted())" } ?? "\(battery.cycles)",
                    help: "One cycle is using 100% of the battery's capacity, in one go or across several charges.")
                if let full = battery.fullCapacity, let design = battery.designCapacity {
                    row("Capacity", "\(full.formatted()) of \(design.formatted()) mAh")
                }
                row(battery.watts >= 0 ? "Charging" : "Drawing", String(format: "%.1f W", abs(battery.watts)))
                if let adapter = battery.adapterWatts { row("Charger", "\(adapter) W") }
                row("Temperature", temperature)
            }
            .font(.system(size: 11))
        }
    }

    private var status: String {
        let time = battery.minutesRemaining.map { m in m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }
        if battery.fullyCharged { return "Fully charged" }
        if battery.isCharging { return time.map { "Charging, \($0) to full" } ?? "Charging" }
        if battery.onPower { return "On power, not charging" }
        return time.map { "\($0) left" } ?? "On battery"
    }

    private var chargeColor: Color {
        if battery.isCharging || battery.onPower { return .green }
        switch battery.percent {
        case ..<10: return .red
        case ..<20: return .orange
        default: return .green
        }
    }

    private func row(_ label: String, _ value: String, help: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .help(help ?? "")
    }
}

/// Right-click actions for a row in "Heating your Mac".
struct RowMenu: View {
    @ObservedObject var store: Store
    let name: String
    let bundlePath: String?

    var body: some View {
        let count = store.processCount(name: name)
        let quittable = store.canQuit(name: name, bundlePath: bundlePath)
        Text(count == 0 ? "Not running" : count == 1 ? "1 process" : "\(count) processes")
        Divider()
        Button("Quit \(name)") { store.quitProcesses(name: name, bundlePath: bundlePath, force: false) }
            .disabled(!quittable)
        Button("Force Quit \(name)…") { confirmForceQuit() }
            .disabled(!quittable)
        Divider()
        Button("Show in Finder") { store.revealInFinder(name: name, bundlePath: bundlePath) }
            .disabled(!store.canReveal(name: name, bundlePath: bundlePath))
        Button("Open Activity Monitor") { store.openActivityMonitor() }
    }

    private func confirmForceQuit() {
        let alert = NSAlert()
        alert.messageText = "Force quit \(name)?"
        alert.informativeText = "Any unsaved changes in \(name) will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            store.quitProcesses(name: name, bundlePath: bundlePath, force: true)
        }
    }
}
