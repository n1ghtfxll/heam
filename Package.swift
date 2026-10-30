// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "heam",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned exactly: the updater is security-critical, so upgrades are deliberate.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "CHeam",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "HeamShared"),
        .executableTarget(
            name: "heam",
            dependencies: ["CHeam", "HeamShared", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in Contents/Frameworks by build.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "HeamWidget",
            dependencies: ["HeamShared"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.linkedFramework("WidgetKit"), .unsafeFlags(["-Xlinker", "-application_extension"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
