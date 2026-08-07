// swift-tools-version: 6.0
// oFinder – macOS Finder clone
// Build with:   swift build -c release
// Test with:    swift test
// Bundle with:  Scripts/bundle.sh <version>   →  .build/oFinder.app
import PackageDescription

let package = Package(
    name: "OFinder",
    // English is the base language; translations live in <lang>.lproj
    // alongside it. Required before SwiftPM will process .lproj resources.
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        // Service layer: filesystem, volumes, rsync transfers, 7zz archives.
        .target(
            name: "OFinderServices",
            path: "Sources/OFinderServices",
            resources: [.process("Resources")]
        ),
        // The app: entry point + AppKit UI. Named ofinder so the produced
        // binary matches CFBundleExecutable in Info.plist.
        .executableTarget(
            name: "ofinder",
            dependencies: ["OFinderServices"],
            path: "Sources/OFinder",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OFinderTests",
            dependencies: ["OFinderServices"],
            path: "Tests/OFinderTests"
        ),
    ]
)
