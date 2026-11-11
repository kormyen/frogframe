// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Frogframe",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Frogframe", targets: ["PhotoTab"])],
    targets: [
        .executableTarget(name: "PhotoTab"),
        .testTarget(name: "PhotoTabTests", dependencies: ["PhotoTab"])
    ]
)
