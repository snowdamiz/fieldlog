// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "FieldLogGenerated", platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "FieldLogFeatures", targets: ["FieldLogFeatures"]), .library(name: "FieldLogModels", targets: ["FieldLogModels"]), .library(name: "FieldLogStorage", targets: ["FieldLogStorage"])],
    dependencies: [.package(path: "Generated/MixerSDK")],
    targets: [
        .target(name: "FieldLogModels"),
        .target(name: "FieldLogFeatures", dependencies: ["FieldLogModels", .product(name: "MixerCore", package: "MixerSDK"), .product(name: "MixerUI", package: "MixerSDK")], exclude: ["TaskEditorAppleFieldsHost.swift", "EntryEditorAppleHost.swift"]),
        .target(name: "FieldLogStorage", dependencies: ["FieldLogModels"]),
    ]
)
