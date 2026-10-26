// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LexiconBuilder",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LexiconBuilderCore", targets: ["LexiconBuilderCore"]),
        .executable(name: "lexicon-builder", targets: ["lexicon-builder"]),
    ],
    targets: [
        .target(name: "LexiconBuilderCore"),
        .executableTarget(name: "lexicon-builder", dependencies: ["LexiconBuilderCore"]),
        .testTarget(name: "LexiconBuilderCoreTests", dependencies: ["LexiconBuilderCore"]),
    ]
)
