// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIElementsSwift",
    platforms: [.macOS("14.2"), .iOS(.v17)],
    products: [.library(name: "AIElementsSwift", targets: ["AIElementsSwift"])],
    targets: [
        .target(name: "AIElementsSwift", resources: [.copy("Resources")]),
        .testTarget(name: "AIElementsSwiftTests", dependencies: ["AIElementsSwift"])
    ]
)
