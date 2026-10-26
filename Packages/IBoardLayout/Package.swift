// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IBoardLayout",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardLayout", targets: ["IBoardLayout"])],
    
    targets: [
        .target(name: "IBoardLayout"),
        .testTarget(name: "IBoardLayoutTests", dependencies: ["IBoardLayout"]),
    ],
    swiftLanguageModes: [.v6]
)
