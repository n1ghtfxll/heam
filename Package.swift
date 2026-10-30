// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "heam",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CHeam",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "HeamShared"),
        .executableTarget(name: "heam", dependencies: ["CHeam", "HeamShared"]),
        .executableTarget(
            name: "HeamWidget",
            dependencies: ["HeamShared"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.linkedFramework("WidgetKit"), .unsafeFlags(["-Xlinker", "-application_extension"])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
