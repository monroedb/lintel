// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lintel",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Lintel", targets: ["Lintel"]),
    ],
    targets: [
        // Pure, UI-free logic: settings registry/store, display planning, geometry,
        // interaction state machine, timing constants. Checked by `lintel-checks`.
        .target(name: "LintelCore"),

        // The app (AppKit + SwiftUI). Assembled into Lintel.app by scripts/build-app.sh.
        .executableTarget(
            name: "Lintel",
            dependencies: ["LintelCore"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),

        // Assertion runner for LintelCore (XCTest/swift-testing need full Xcode).
        .executableTarget(
            name: "lintel-checks",
            dependencies: ["LintelCore"],
            path: "Sources/LintelChecks"
        ),
    ]
)
