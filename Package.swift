// swift-tools-version: 6.0
import PackageDescription

// libusb is the only native dependency; the MTP protocol itself is implemented in MTPKit.
//
// It is built from source into Vendor/ by Scripts/build-libusb.sh and linked statically, so a
// finished .app depends on nothing but system frameworks. Run that script once after cloning.

let package = Package(
    name: "Porterage",
    platforms: [.macOS(.v14)],
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
    ]
)
