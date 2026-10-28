// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FieldLog",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "FieldLogModels", targets: ["FieldLogModels"]), .library(name: "FieldLogStorage", targets: ["FieldLogStorage"]), .library(name: "FieldLogFeatures", targets: ["FieldLogFeatures"])],
    dependencies: [.package(url: "https://github.com/snowdamiz/mixer.git", revision: "56ff14c925168284761c5aca4f0bd4129cf3c995")],
    targets: [
        .target(name: "FieldLogModels"),
        .target(name: "FieldLogStorage", dependencies: ["FieldLogModels"]),
        .target(name: "FieldLogFeatures", dependencies: ["FieldLogModels", .product(name: "MixerCore", package: "mixer"), .product(name: "MixerUI", package: "mixer"), .product(name: "MixerApple", package: "mixer", condition: .when(platforms: [.iOS, .macOS]))]),
        .testTarget(name: "FieldLogTests", dependencies: ["FieldLogModels", "FieldLogStorage", "FieldLogFeatures", .product(name: "MixerUI", package: "mixer"), .product(name: "MixerApple", package: "mixer", condition: .when(platforms: [.iOS, .macOS]))])
    ]
)
