// swift-tools-version: 6.0
import PackageDescription
import Foundation

let localSDK = ProcessInfo.processInfo.environment["FIELDLOG_MIXER_SDK"]
let mixer: Package.Dependency = localSDK.map { .package(name: "mixer", path: $0) } ??
    .package(url: "https://github.com/snowdamiz/mixer.git", revision: "8efc1a9e5b1602117f8211c95bfd4203cc91f689")

let package = Package(
    name: "FieldLog",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "AppAndroid", type: .dynamic, targets: ["FieldLogAndroid"]), .library(name: "FieldLogModels", targets: ["FieldLogModels"]), .library(name: "FieldLogStorage", targets: ["FieldLogStorage"]), .library(name: "FieldLogFeatures", targets: ["FieldLogFeatures"])],
    dependencies: [mixer],
    targets: [
        .target(name: "FieldLogModels"),
        .target(name: "FieldLogStorage", dependencies: ["FieldLogModels"]),
        .target(name: "FieldLogFeatures", dependencies: ["FieldLogModels", .product(name: "MixerCore", package: "mixer"), .product(name: "MixerUI", package: "mixer"), .product(name: "MixerApple", package: "mixer", condition: .when(platforms: [.iOS, .macOS]))]),
        .target(name: "FieldLogAndroid", dependencies: ["FieldLogModels", "FieldLogStorage", "FieldLogFeatures", .product(name: "MixerCore", package: "mixer"), .product(name: "MixerUI", package: "mixer"), .product(name: "MixerAndroid", package: "mixer")]),
        .testTarget(name: "FieldLogAndroidTests", dependencies: ["FieldLogAndroid", "FieldLogModels", "FieldLogStorage", .product(name: "MixerUI", package: "mixer"), .product(name: "MixerAndroid", package: "mixer")]),
        .testTarget(name: "FieldLogTests", dependencies: ["FieldLogModels", "FieldLogStorage", "FieldLogFeatures", .product(name: "MixerUI", package: "mixer"), .product(name: "MixerApple", package: "mixer", condition: .when(platforms: [.iOS, .macOS]))])
    ]
)
