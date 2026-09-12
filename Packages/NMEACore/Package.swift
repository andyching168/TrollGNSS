// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NMEACore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "NMEACore", targets: ["NMEACore"])],
    targets: [
        .target(name: "NMEACore"),
        .testTarget(name: "NMEACoreTests", dependencies: ["NMEACore"]),
    ]
)
