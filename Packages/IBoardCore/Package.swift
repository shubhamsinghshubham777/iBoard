// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IBoardCore",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardCore", targets: ["IBoardCore"])],
    
    targets: [
        .target(name: "IBoardCore"),
        .testTarget(name: "IBoardCoreTests", dependencies: ["IBoardCore"]),
    ],
    swiftLanguageModes: [.v6]
)
