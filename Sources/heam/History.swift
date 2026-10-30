import Foundation
import HeamShared

/// Running totals for the current day: energy per app and the day's peaks.
struct DailyHistory: Codable {
    struct App: Codable {
        var bundlePath: String?
        var joules: Double
        /// Seconds this app was the biggest energy user.
        var secondsOnTop: Double
        /// Sum of (degrees attributed × seconds), for the day's average heat.
        var degreeSeconds: Double
        var seconds: Double
        var peakDegrees: Double

    }

    var day: String
    var apps: [String: App] = [:]
    var peakTemp: Double = 0
    var peakChip: Double = 0
    var systemJoules: Double = 0
    /// Seconds heam has been measuring today; the denominator for each app's share of the day's heat.
    var trackedSeconds: Double = 0

    /// Degrees an app added, averaged over everything measured today. Comparable across apps
    /// whether they ran for a minute or all day, and it sorts the same way as total heat.
    func dayAverage(_ app: App) -> Double { trackedSeconds > 0 ? app.degreeSeconds / trackedSeconds : 0 }

    static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func load() -> DailyHistory {
        if let data = try? Data(contentsOf: SharedFiles.history),
           let saved = try? JSONDecoder().decode(DailyHistory.self, from: data),
           saved.day == today() {
            return saved
        }
        return DailyHistory(day: today())
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: SharedFiles.history, options: .atomic) }
    }

    mutating func record(impacts: [AppImpact], systemWatts: Double?, temp: Double, chip: Double?, seconds: Double) {
        if day != Self.today() { self = DailyHistory(day: Self.today()) }
        trackedSeconds += seconds
        peakTemp = max(peakTemp, temp)
        peakChip = max(peakChip, chip ?? 0)
        if let w = systemWatts { systemJoules += w * seconds }
        for (i, app) in impacts.enumerated() {
            var entry = apps[app.name] ?? App(bundlePath: app.bundlePath, joules: 0, secondsOnTop: 0,
                                              degreeSeconds: 0, seconds: 0, peakDegrees: 0)
            // Without per-process energy, estimate from the app's share of system power.
            if let watts = app.watts ?? systemWatts.map({ $0 * app.share }) { entry.joules += watts * seconds }
            entry.degreeSeconds += app.degrees * seconds
            entry.seconds += seconds
            entry.peakDegrees = max(entry.peakDegrees, app.degrees)
            if i == 0 { entry.secondsOnTop += seconds }
            apps[app.name] = entry
        }
    }

    var ranked: [(name: String, app: App)] {
        apps.map { ($0.key, $0.value) }.sorted { $0.app.degreeSeconds > $1.app.degreeSeconds }
    }
}
