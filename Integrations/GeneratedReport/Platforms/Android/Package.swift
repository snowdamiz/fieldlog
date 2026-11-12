// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FieldLogGeneratedAndroid", platforms: [.macOS(.v14)],
    products: [.library(name: "AppAndroid", type: .dynamic, targets: ["FieldLogAndroid"])],
    dependencies: [.package(name: "Application", path: "../.."), .package(path: "../../Generated/MixerSDK")],
    targets: [
        .target(name: "FieldLogAndroid", dependencies: [.product(name: "FieldLogFeatures", package: "Application"), .product(name: "FieldLogModels", package: "Application"), .product(name: "FieldLogStorage", package: "Application"),
            .product(name: "MixerAndroid", package: "MixerSDK"), .product(name: "MixerCore", package: "MixerSDK"), .product(name: "MixerUI", package: "MixerSDK")], path: "Sources/AppAndroid"),
        .testTarget(name: "FieldLogAndroidTests", dependencies: ["FieldLogAndroid", .product(name: "FieldLogModels", package: "Application"), .product(name: "FieldLogStorage", package: "Application"), .product(name: "MixerAndroid", package: "MixerSDK"), .product(name: "MixerUI", package: "MixerSDK")], path: "Tests/AppAndroidTests")
    ], swiftLanguageModes: [.v6])
