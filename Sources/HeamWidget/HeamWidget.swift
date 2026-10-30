import Charts
import HeamShared
import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: context.isPreview ? .preview : Snapshot.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app asks for reloads while it runs; this is the fallback refresh.
        let entry = Entry(date: Date(), snapshot: Snapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
    }
}

extension Snapshot {
    static let preview = Snapshot(
        date: Date(), temp: 52, chip: 61, watts: 18, fahrenheit: false,
        topApps: [.init(name: "Minecraft", bundlePath: nil, degrees: 9.4),
                  .init(name: "Safari", bundlePath: nil, degrees: 2.1),
                  .init(name: "Xcode", bundlePath: nil, degrees: 1.2)],
        history: (0..<60).map { 48 + 6 * sin(Double($0) / 9) })
}

func heatColor(_ celsius: Double) -> Color {
    switch celsius {
    case ..<55: .green
    case ..<70: .yellow
    case ..<85: .orange
    default: .red
    }
}

struct HeamWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        Group {
            if let s = entry.snapshot {
                switch family {
                case .systemSmall: small(s)
                default: medium(s)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "thermometer.medium").font(.title2)
                    Text("Open heam to start measuring").font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [heatColor(entry.snapshot?.temp ?? 40).opacity(0.18), .clear],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private func stale(_ s: Snapshot) -> Bool { entry.date.timeIntervalSince(s.date) > 10 * 60 }

    private func header(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("heam", systemImage: "thermometer.medium")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(s.format(s.temp))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .tracking(-1)
                .monospacedDigit()
                .foregroundStyle(heatColor(s.temp).gradient)
                .minimumScaleFactor(0.6)
            HStack(spacing: 8) {
                if let c = s.chip { Label(s.format(c), systemImage: "cpu") }
                if let w = s.watts { Label(String(format: "%.0f W", w), systemImage: "bolt.fill") }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            if stale(s) {
                Text("as of \(s.date, style: .time)").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private func small(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(s)
            Spacer(minLength: 0)
            if let top = s.topApps.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Top heat").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("\(top.name) +\(String(format: "%.0f", top.degrees))°")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ s: Snapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header(s)
                Spacer(minLength: 0)
                Chart(Array(s.history.enumerated()), id: \.offset) { p in
                    LineMark(x: .value("t", p.offset), y: .value("°", p.element))
                        .foregroundStyle(heatColor(s.temp))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 26)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Heating your Mac").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(s.topApps.prefix(3), id: \.name) { app in
                    HStack {
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "+%.1f°", s.fahrenheit ? app.degrees * 9 / 5 : app.degrees))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

@main
struct HeamWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HeamTemperature", provider: Provider()) { entry in
            HeamWidgetView(entry: entry)
        }
        .configurationDisplayName("Temperature")
        .description("Your Mac's temperature, power draw and the apps heating it up.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
