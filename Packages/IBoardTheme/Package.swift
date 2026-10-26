// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IBoardTheme",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardTheme", targets: ["IBoardTheme"])],
    
    targets: [
        .target(name: "IBoardTheme"),
        .testTarget(name: "IBoardThemeTests", dependencies: ["IBoardTheme"]),
    ],
    swiftLanguageModes: [.v6]
)
