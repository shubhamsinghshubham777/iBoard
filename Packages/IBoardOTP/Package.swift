// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IBoardOTP",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "IBoardOTP", targets: ["IBoardOTP"])],
    
    targets: [
        .target(name: "IBoardOTP"),
        .testTarget(name: "IBoardOTPTests", dependencies: ["IBoardOTP"]),
    ],
    swiftLanguageModes: [.v6]
)
