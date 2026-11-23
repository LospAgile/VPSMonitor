// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KomariMenuBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KomariMonitor", targets: ["KomariMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "KomariMonitor",
            path: "Sources/KomariMonitor",
            exclude: ["KomariLogo.png"]
        ),
        .testTarget(
            name: "KomariMonitorTests",
            dependencies: ["KomariMonitor"],
            path: "Tests/KomariMonitorTests"
        )
    ]
)
