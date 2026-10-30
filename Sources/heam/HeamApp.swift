import AppKit
import SwiftUI

struct HeamApp: App {
    @StateObject private var store = Store()

    init() {
        _ = Updater.shared // start Sparkle's scheduled checks at launch
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            // MenuBarExtra ignores SwiftUI font modifiers on its label, so draw it ourselves.
            Image(nsImage: MenuBarLabel.image(symbol: symbol, text: store.menuBarText))
        }
        .menuBarExtraStyle(.window)
    }

    private var symbol: String {
        switch store.menuBarItem {
        case .power: return "bolt.fill"
        case .fan: return "fan.fill"
        case .chip: return thermometerSymbol(store.chip)
        case .temperature, .temperatureAndPower: return thermometerSymbol(store.current)
        }
    }

    private func thermometerSymbol(_ celsius: Double?) -> String {
        switch celsius ?? 0 {
        case ..<50: "thermometer.low"
        case ..<75: "thermometer.medium"
        default: "thermometer.high"
        }
    }
}

/// Renders the status item the way the menu bar clock does: the system menu bar font with
/// fixed-width digits, as a template image so macOS tints it for light, dark and highlighted bars.
enum MenuBarLabel {
    /// The font the clock uses, with digits that are all the same width.
    static let font: NSFont = {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }()

    private static let thermometers = ["thermometer.low", "thermometer.medium", "thermometer.high"]
    private static let gap: CGFloat = 4
    private static var cache: (key: String, image: NSImage)?

    static func image(symbol: String, text: String) -> NSImage {
        let key = symbol + "|" + text
        if let cache, cache.key == key { return cache.image }

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let string = NSAttributedString(string: text, attributes: attributes)
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)

        // The thermometer swaps between three fills; reserve the widest so the text never shifts.
        let slot = (thermometers.contains(symbol) ? thermometers : [symbol])
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config)?.size.width }
            .max() ?? 0
        let textSize = string.size()
        let height = NSStatusBar.system.thickness
        let size = NSSize(width: ceil(slot + gap + textSize.width), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            if let glyph {
                let g = glyph.size
                glyph.draw(in: NSRect(x: (slot - g.width) / 2, y: (height - g.height) / 2, width: g.width, height: g.height))
            }
            // Pixel-aligned so the text stays crisp on non-Retina displays.
            string.draw(at: NSPoint(x: slot + gap, y: ((height - textSize.height) / 2).rounded()))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = text
        cache = (key, image)
        return image
    }
}
