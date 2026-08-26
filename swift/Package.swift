// swift-tools-version:5.9
// Golf: read-only indexed storage file format for time-series range queries.
import PackageDescription

let package = Package(
    name: "Golf",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "Golf", targets: ["Golf"]),
        .executable(name: "GolfFixtures", targets: ["GolfFixtures"]),
    ],
    targets: [
        .target(
            name: "Golf",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "GolfFixtures",
            dependencies: ["Golf"]
        ),
        .testTarget(
            name: "GolfTests",
            dependencies: ["Golf"]
        ),
    ]
)
