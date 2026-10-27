// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IBoardEngine",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardEngine", targets: ["IBoardEngine"])],
    dependencies: [
        .package(path: "../IBoardCore"),
        .package(path: "../IBoardLayout"),
    ],
    targets: [
        .target(name: "IBoardEngine", dependencies: [
            .product(name: "IBoardLayout", package: "IBoardLayout"),
        ]),
        .testTarget(
            name: "IBoardEngineTests",
            dependencies: [
                "IBoardEngine",
                .product(name: "IBoardCore", package: "IBoardCore"),
                .product(name: "IBoardLayout", package: "IBoardLayout"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
