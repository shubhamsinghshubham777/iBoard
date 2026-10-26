// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IBoardSync",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardSync", targets: ["IBoardSync"])],
    targets: [
        .target(name: "IBoardSync"),
        .testTarget(name: "IBoardSyncTests", dependencies: ["IBoardSync"]),
    ],
    swiftLanguageModes: [.v6]
)
