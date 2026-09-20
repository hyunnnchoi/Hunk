// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hunk",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Hunk", targets: ["Hunk"])],
    targets: [
        .executableTarget(name: "Hunk"),
        .testTarget(name: "HunkTests", dependencies: ["Hunk"])
    ]
)
