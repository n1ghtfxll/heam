// Renders the DMG window background at 1x and 2x and combines them into one HiDPI TIFF.
// Usage: swift scripts/make-dmg-background.swift Resources/dmg-background.tiff
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/dmg-background.tiff"

/// Window content size in points. Keep in sync with scripts/dmg-settings.py.
let size = CGSize(width: 660, height: 400)
/// Icon centers in points, measured from the top-left like Finder.
// Kept high so the layout clears Finder's path and status bars, which some people keep on.
let appCenter = CGPoint(x: 190, y: 196)
let folderCenter = CGPoint(x: 470, y: 196)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size // points, so the TIFF carries the right DPI for each layer
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // rep.size is in points, so the context already maps points to this layer's pixels.
    let ctx = NSGraphicsContext.current!.cgContext
    // Flip so drawing coordinates match Finder's top-left origin.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    // Ground: Apple's light neutral, a touch lighter at the top.
    NSGradient(colors: [NSColor(red: 0.975, green: 0.975, blue: 0.98, alpha: 1),
                        NSColor(red: 0.93, green: 0.93, blue: 0.945, alpha: 1)])!
        .draw(in: CGRect(origin: .zero, size: size), angle: 90)

    // Warm glow behind the app icon, in the icon's own amber-to-coral, very low strength.
    let glow = NSGradient(colors: [NSColor(red: 1.0, green: 0.55, blue: 0.2, alpha: 0.20),
                                   NSColor(red: 1.0, green: 0.4, blue: 0.3, alpha: 0)])!
    glow.draw(fromCenter: appCenter, radius: 0, toCenter: appCenter, radius: 150, options: [])

    // Arrow from app to Applications: one rounded stroke with an open chevron head.
    let from = CGPoint(x: appCenter.x + 88, y: appCenter.y)
    let to = CGPoint(x: folderCenter.x - 88, y: folderCenter.y)
    let arrow = NSBezierPath()
    arrow.move(to: from)
    arrow.line(to: to)
    arrow.move(to: CGPoint(x: to.x - 12, y: to.y - 11))
    arrow.line(to: to)
    arrow.line(to: CGPoint(x: to.x - 12, y: to.y + 11))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(red: 1.0, green: 0.52, blue: 0.2, alpha: 0.9).setStroke()
    arrow.stroke()

    // Text, drawn unflipped so glyphs aren't mirrored.
    func text(_ string: String, size pt: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, tracking: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pt, weight: weight),
            .foregroundColor: color,
            .kern: tracking,
        ]
        let s = NSAttributedString(string: string, attributes: attrs)
        let w = s.size()
        ctx.saveGState()
        ctx.translateBy(x: 0, y: y + w.height)
        ctx.scaleBy(x: 1, y: -1)
        s.draw(at: CGPoint(x: (size.width - w.width) / 2, y: 0))
        ctx.restoreGState()
    }
    text("Install heam", size: 22, weight: .semibold, color: NSColor(white: 0.11, alpha: 1), y: 36, tracking: -0.3)
    text("Drag heam into your Applications folder", size: 13, weight: .regular,
         color: NSColor(white: 0.43, alpha: 1), y: 67)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heam-dmg-bg")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let one = dir.appendingPathComponent("bg.png"), two = dir.appendingPathComponent("bg@2x.png")
try! render(scale: 1).representation(using: .png, properties: [:])!.write(to: one)
try! render(scale: 2).representation(using: .png, properties: [:])!.write(to: two)
try! render(scale: 2).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))

let tiff = Process()
tiff.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiff.arguments = ["-cathidpicheck", one.path, two.path, "-out", output]
try! tiff.run()
tiff.waitUntilExit()
print("Wrote \(output)")
