// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PowerEmu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PowerEmu",
            path: "Sources/PowerEmu"
        )
    ]
)
