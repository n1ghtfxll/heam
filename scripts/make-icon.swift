// Renders heam's app icon. Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a continuous-corner rounded rect.
    let inset = size * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()

    // Warm diagonal gradient: amber top-left to hot pink-red bottom-right.
    path.addClip()
    NSGradient(colors: [NSColor(red: 1.0, green: 0.74, blue: 0.20, alpha: 1),
                        NSColor(red: 1.0, green: 0.42, blue: 0.18, alpha: 1),
                        NSColor(red: 0.93, green: 0.18, blue: 0.36, alpha: 1)])!
        .draw(in: body, angle: -55)

    // Top sheen, as light catching the material.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    // Heat waves behind the thermometer.
    let waves = NSBezierPath()
    for i in 0..<3 {
        let x = body.minX + body.width * (0.25 + CGFloat(i) * 0.25)
        let amp = body.width * 0.035
        waves.move(to: CGPoint(x: x, y: body.minY + body.height * 0.18))
        for step in 1...24 {
            let t = CGFloat(step) / 24
            waves.line(to: CGPoint(x: x + sin(t * .pi * 4) * amp, y: body.minY + body.height * (0.18 + t * 0.64)))
        }
    }
    waves.lineWidth = body.width * 0.035
    waves.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.16).setStroke()
    waves.stroke()

    // White thermometer glyph.
    let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        let rect = CGRect(x: body.midX - s.width / 2, y: body.midY - s.height / 2, width: s.width, height: s.height)
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.008), blur: size * 0.02,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)
        symbol.draw(in: rect)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("heam.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(1024).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
print("Wrote \(output)")
