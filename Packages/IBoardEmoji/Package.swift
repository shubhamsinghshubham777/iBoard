// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IBoardEmoji",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardEmoji", targets: ["IBoardEmoji"])],
    targets: [
        .target(name: "IBoardEmoji", resources: [.copy("Resources/emoji.json")]),
        .testTarget(name: "IBoardEmojiTests", dependencies: ["IBoardEmoji"]),
    ],
    swiftLanguageModes: [.v6]
)
