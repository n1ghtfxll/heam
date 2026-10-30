import AppKit
import UserNotifications

/// Notifies when the chip stays hot, or when macOS starts throttling, and names the app causing it.
@MainActor
final class AlertManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let thresholds: [Double] = [80, 85, 90, 95, 100]
    static let durations: [TimeInterval] = [30, 60, 120, 300]

    @Published var hotEnabled: Bool { didSet { save(hotEnabled, "alertHot"); requestPermissionIfNeeded() } }
    @Published var threshold: Double { didSet { save(threshold, "alertThreshold") } }
    @Published var duration: TimeInterval { didSet { save(duration, "alertDuration") } }
    @Published var throttleEnabled: Bool { didSet { save(throttleEnabled, "alertThrottle"); requestPermissionIfNeeded() } }
    @Published private(set) var permissionDenied = false

    /// Re-arm only once the chip has cooled this far below the threshold, so one hot session sends one alert.
    private static let hysteresis = 5.0
    nonisolated private static let quitAction = "quit-app"

    private var hotSince: Date?
    private var hotAlerted = false
    private var throttleAlerted = false
    /// nil when running outside the app bundle (e.g. `heam --dump`), where UserNotifications throws.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    override init() {
        let d = UserDefaults.standard
        hotEnabled = d.object(forKey: "alertHot") as? Bool ?? true
        threshold = d.object(forKey: "alertThreshold") as? Double ?? 90
        duration = d.object(forKey: "alertDuration") as? TimeInterval ?? 120
        throttleEnabled = d.object(forKey: "alertThrottle") as? Bool ?? true
        super.init()
        center?.delegate = self
        requestPermissionIfNeeded()
    }

    func evaluate(chip: Double?, thermal: ProcessInfo.ThermalState, impacts: [AppImpact],
                  format: (Double?) -> String) {
        let culprit = impacts.first { $0.bundlePath != Bundle.main.bundlePath }

        if hotEnabled, let chip {
            if chip >= threshold {
                hotSince = hotSince ?? Date()
                if !hotAlerted, Date().timeIntervalSince(hotSince!) >= duration {
                    hotAlerted = true
                    var body = "Above \(format(threshold)) for \(Self.describe(duration)), now \(format(chip))."
                    if let c = culprit {
                        body += " \(c.name) is the main cause (\(String(format: "%.0f", c.share * 100))% of CPU energy)."
                    }
                    send(title: "Your Mac is running hot", body: body, culprit: culprit)
                }
            } else {
                // Die sensors are jumpy; a brief dip shouldn't restart the "hot for N minutes" clock.
                if chip < threshold - 2 { hotSince = nil }
                if chip < threshold - Self.hysteresis { hotAlerted = false }
            }
        }

        if throttleEnabled {
            if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                if !throttleAlerted {
                    throttleAlerted = true
                    var body = "macOS is slowing your Mac down to cool it."
                    if let c = culprit { body += " \(c.name) is using the most energy." }
                    send(title: "Your Mac is throttling", body: body, culprit: culprit)
                }
            } else if thermal == .nominal {
                throttleAlerted = false
            }
        }
    }

    func sendTest(chip: Double?, impacts: [AppImpact], format: (Double?) -> String) {
        let culprit = impacts.first { $0.bundlePath != Bundle.main.bundlePath }
        var body = "Test alert. Chip is at \(format(chip)); you'll be alerted above \(format(threshold)) for \(Self.describe(duration))."
        if let c = culprit { body += " Right now \(c.name) uses the most energy." }
        send(title: "heam alerts are on", body: body, culprit: nil)
    }

    static func describe(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) seconds" : seconds == 60 ? "1 minute" : "\(Int(seconds / 60)) minutes"
    }

    // MARK: Delivery

    private func send(title: String, body: String, culprit: AppImpact?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let culprit, let path = culprit.bundlePath {
            // Action titles are fixed per category, so register one naming this app.
            center?.setNotificationCategories([
                UNNotificationCategory(identifier: "hot",
                                       actions: [UNNotificationAction(identifier: Self.quitAction,
                                                                      title: "Quit \(culprit.name)")],
                                       intentIdentifiers: []),
            ])
            content.categoryIdentifier = "hot"
            content.userInfo = ["bundlePath": path]
        }
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func requestPermissionIfNeeded() {
        guard hotEnabled || throttleEnabled else { return }
        center?.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.permissionDenied = !granted }
        }
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }

    // heam is a menu bar app, so it is always "in the foreground"; show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.quitAction,
              let path = response.notification.request.content.userInfo["bundlePath"] as? String else { return }
        await MainActor.run {
            // Polite quit, same as ⌘Q: the app can still ask to save documents.
            for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path == path {
                app.terminate()
            }
        }
    }
}
