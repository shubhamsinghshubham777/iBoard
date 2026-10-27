// swift-tools-version: 6.2
import PackageDescription

// App-only glue between the personal model (IBoardEngine) and iCloud sync (IBoardSync).
// The keyboard extension must never link this package (privacy: no network/CloudKit in the keyboard).
let package = Package(
    name: "IBoardPersonalSync",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardPersonalSync", targets: ["IBoardPersonalSync"])],
    dependencies: [
        .package(path: "../IBoardEngine"),
        .package(path: "../IBoardSync"),
    ],
    targets: [
        .target(name: "IBoardPersonalSync", dependencies: [
            .product(name: "IBoardEngine", package: "IBoardEngine"),
            .product(name: "IBoardSync", package: "IBoardSync"),
        ]),
        .testTarget(name: "IBoardPersonalSyncTests", dependencies: ["IBoardPersonalSync"]),
    ],
    swiftLanguageModes: [.v6]
)
