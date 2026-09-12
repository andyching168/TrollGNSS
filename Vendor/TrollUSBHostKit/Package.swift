// swift-tools-version: 5.9
// USBHostKit: SwiftUSB wrapper over the pinned UTM libusb fork.
// Kept independent of AdbKit so it can be reused by HeadunitPad.
import PackageDescription

let package = Package(
    name: "TrollUSBHostKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v14),
    ],
    products: [
        .library(name: "USBHostKit", targets: ["USBHostKit"]),
    ],
    targets: [
        // Vendored UTM libusb fork (utm-edition branch, pinned commit
        // 9eaebb714169264c346bcba0100ac650aba40002) compiled as a C target.
        // `ios-headers/` carries vendored copies of the IOKit USB headers missing
        // from the iOS SDK, patched per the UTM build script (strip
        // `__UNAVAILABLE_PUBLIC_IOS;`). They are only on the search path for iOS
        // so they do not shadow the macOS SDK framework modules.
        .target(
            name: "CLibusb",
            cSettings: [
                .headerSearchPath("libusb"),
                .headerSearchPath("ios-headers", .when(platforms: [.iOS])),
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Small C shim giving the Swift layer a stable, opaque surface.
        .target(
            name: "CUSBShim",
            dependencies: ["CLibusb"]
        ),
        .target(
            name: "USBHostKit",
            dependencies: ["CUSBShim"]
        ),
        .testTarget(
            name: "USBHostKitTests",
            dependencies: ["USBHostKit"]
        ),
    ],
    cLanguageStandard: .gnu11
)
