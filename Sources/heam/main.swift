import SwiftUI

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--fan-daemon") {
    let uid = args.indices.contains(i + 1) ? uid_t(args[i + 1]) ?? 0 : 0
    FanDaemon.run(ownerUID: uid)
} else if args.contains("--dump") {
    // Debug aid: print what the app sees, then exit.
    for s in Sensors.read() { print(String(format: "%6.1f°  %@", s.celsius, s.name)) }
    for f in Fans.read() { print("\(f.name): \(Int(f.rpm)) rpm (\(Int(f.minRPM))–\(Int(f.maxRPM)))") }
    let g1 = GPUUsage.timeByPID()
    sleep(2)
    let g2 = GPUUsage.timeByPID()
    for (pid, t) in g2.sorted(by: { ($0.value &- (g1[$0.key] ?? $0.value)) > ($1.value &- (g1[$1.key] ?? $1.value)) }).prefix(6) {
        guard let old = g1[pid], t > old else { continue }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, 256)
        print(String(format: "GPU busy %5.1f%%  %@ (%d)", Double(t - old) / 2e7, String(cString: name), pid))
    }
    let monitor = ProcessMonitor()
    _ = monitor.sample()
    sleep(2)
    for a in monitor.sample().prefix(10) {
        print(String(format: "%5.1f%%  %5.2f W  %3.0f%% GPU  %@", a.share * 100, a.watts ?? 0, a.gpuFraction * 100, a.name))
    }
} else if let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) {
    // Dev aid: render the popover to a PNG after a few seconds of live data.
    MainActor.assumeIsolated {
        let store = Store()
        store.popoverVisible = true
        RunLoop.main.run(until: Date().addingTimeInterval(args.contains("--demo") ? 1 : 8))
        if args.contains("--demo") { store.loadDemo() }
        @MainActor func write(_ name: String, _ view: some View, scheme: ColorScheme = .dark) {
            let renderer = ImageRenderer(content: view
                .background(scheme == .dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(red: 0.95, green: 0.95, blue: 0.96))
                .environment(\.colorScheme, scheme)
                .environment(\.heamSnapshot, true)
                .environment(\.controlActiveState, .key)
                .environment(\.isEnabled, true))
            renderer.scale = 2
            renderer.isOpaque = true
            renderer.colorMode = .nonLinear
            guard let raw = renderer.cgImage,
                  let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Re-draw into plain sRGB so viewers don't read linear values as sRGB (washed-out PNGs).
            ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
            guard let cg = ctx.makeImage() else { return }
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            try? png?.write(to: URL(fileURLWithPath: args[i + 1] + "-\(name).png"))
        }
        write("light", PopoverView(store: store), scheme: .light)
        write("dark", PopoverView(store: store))
        write("now", ImpactModule(store: store, span: .now).padding(10).frame(width: 360))
        write("today", ImpactModule(store: store, span: .today).padding(10).frame(width: 360))
        write("curve", CurveEditor(store: store).padding(10).frame(width: 340))
        for mode in Store.FanMode.allCases {
            store.previewFanMode(mode)
            write("fans-\(mode.rawValue.lowercased())", FanModule(store: store).padding(10).frame(width: 360))
        }
        store.previewFanMode(.auto)
        // Menu bar label widths across changing readings: they should only differ by digit count.
        for text in ["38°", "43°", "47°", "51°", "88°", "100°"] {
            print("label", text, MenuBarLabel.image(symbol: "thermometer.medium", text: text).size.width)
        }
        for symbol in ["thermometer.low", "thermometer.medium", "thermometer.high"] {
            print("label", symbol, MenuBarLabel.image(symbol: symbol, text: "43°").size.width)
        }
        print("font", MenuBarLabel.font.fontName, MenuBarLabel.font.pointSize)
    }
} else {
    HeamApp.main()
}
