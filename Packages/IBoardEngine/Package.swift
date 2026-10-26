// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IBoardEngine",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardEngine", targets: ["IBoardEngine"])],
    dependencies: [.package(path: "../IBoardCore")],
    targets: [
        .target(name: "IBoardEngine"),
        .testTarget(name: "IBoardEngineTests", dependencies: [
            "IBoardEngine",
            .product(name: "IBoardCore", package: "IBoardCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
