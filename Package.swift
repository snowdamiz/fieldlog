// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FieldLog",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FieldLogModels", targets: ["FieldLogModels"]), .library(name: "FieldLogStorage", targets: ["FieldLogStorage"]), .library(name: "FieldLogFeatures", targets: ["FieldLogFeatures"])],
    dependencies: [.package(url: "https://github.com/snowdamiz/mixer.git", revision: "d8c6965a277ca21e685f3ef9e0f68a7d59b46156")],
    targets: [
        .target(name: "FieldLogModels"),
        .target(name: "FieldLogStorage", dependencies: ["FieldLogModels"]),
        .target(name: "FieldLogFeatures", dependencies: ["FieldLogModels", .product(name: "MixerCore", package: "mixer"), .product(name: "MixerUI", package: "mixer")]),
        .testTarget(name: "FieldLogTests", dependencies: ["FieldLogModels", "FieldLogStorage", "FieldLogFeatures", .product(name: "MixerUI", package: "mixer")])
    ]
)
