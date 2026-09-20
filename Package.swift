// swift-tools-version: 6.0
import PackageDescription

// libusb is the only native dependency; the MTP protocol itself is implemented in MTPKit.
//
// It is built from source into Vendor/ by Scripts/build-libusb.sh and linked statically, so a
// finished .app depends on nothing but system frameworks. Run that script once after cloning.

let package = Package(
    name: "Porterage",
    platforms: [.macOS(.v14)],
    // Tests only. This Mac has the command line tools and no Xcode, so the toolchain ships the
    // testing macros but not the library behind them, and `import Testing` fails on its own. Pulling
    // it in as a package is what makes `swift test` work here at all — 15 MB, fetched once.
    //
    // Pinned exactly, and to 0.99.0 rather than a tag matching the toolchain: the 6.x tags are built
    // for a toolchain-integrated build and fail to link against the command line tools, looking for
    // a `_TestingInterop` library that is not there. Measured on 20 Sep 2026. Do not "upgrade" this
    // to 6.3.2 because it looks tidier; check that `swift test` still runs first.
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "0.99.0"),
    ],
    targets: [
        .systemLibrary(name: "CUSB", path: "Sources/CUSB"),
        .target(
            name: "MTPKit",
            dependencies: ["CUSB"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // The static archive, not -lusb-1.0: linking the dylib would leave the shipped app
            // depending on a Homebrew path that users do not have. IOKit and CoreFoundation are
            // what libusb itself needs on macOS.
            linkerSettings: [.unsafeFlags([
                "Vendor/lib/libusb-1.0.a",
                "-framework", "IOKit",
                "-framework", "CoreFoundation",
                "-framework", "Security",
            ])]
        ),
        .executableTarget(
            name: "PorterageApp",
            dependencies: ["MTPKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Terminal diagnostics: proves the raw MTP layer against real hardware without the GUI in
        // the way, and doubles as what a user runs when reporting a connection problem.
        .executableTarget(
            name: "mtpcheck",
            dependencies: ["MTPKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The rules that need neither a phone nor a window. Everything else in this project needs
        // real hardware, which is exactly why the parts that do not should be pinned down here.
        .testTarget(
            name: "PorterageAppTests",
            dependencies: [
                "PorterageApp",
                "MTPKit",
                .product(name: "Testing", package: "swift-testing"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
