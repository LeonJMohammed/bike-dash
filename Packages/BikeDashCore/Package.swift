// swift-tools-version:5.9
// Logic that doesn't need a phone, so it can be tested with `swift test` on the Mac.
import PackageDescription

let package = Package(
    name: "BikeDashCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BikeDashCore", targets: ["BikeDashCore"]),
    ],
    targets: [
        .target(name: "BikeDashCore"),
        .testTarget(name: "BikeDashCoreTests", dependencies: ["BikeDashCore"]),
    ]
)
