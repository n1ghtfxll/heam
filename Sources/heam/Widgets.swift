import Foundation
import WidgetKit

enum Widgets {
    private static var lastReload = Date.distantPast

    /// Asks the widget to re-read the snapshot. macOS rate-limits this, so once a minute is plenty.
    static func reload() {
        guard Date().timeIntervalSince(lastReload) >= 60 else { return }
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
