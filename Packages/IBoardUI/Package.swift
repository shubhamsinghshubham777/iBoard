// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IBoardUI",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardUI", targets: ["IBoardUI"])],
    dependencies: [
        .package(path: "../IBoardCore"),
        .package(path: "../IBoardLayout"),
        .package(path: "../IBoardEngine"),
        .package(path: "../IBoardTheme"),
        .package(path: "../IBoardOTP"),
    ],
    targets: [
        .target(name: "IBoardUI", dependencies: [
            .product(name: "IBoardCore", package: "IBoardCore"),
            .product(name: "IBoardLayout", package: "IBoardLayout"),
            .product(name: "IBoardEngine", package: "IBoardEngine"),
            .product(name: "IBoardTheme", package: "IBoardTheme"),
            .product(name: "IBoardOTP", package: "IBoardOTP"),
        ]),
        .testTarget(name: "IBoardUITests", dependencies: [
            "IBoardUI",
            .product(name: "IBoardEngine", package: "IBoardEngine"),
            .product(name: "IBoardTheme", package: "IBoardTheme"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
