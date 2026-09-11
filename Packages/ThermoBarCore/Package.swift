// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ThermoBarCore",
    platforms: [.macOS("27.0")],
    products: [.library(name: "ThermoBarCore", targets: ["ThermoBarCore"])],
    targets: [
        .target(name: "ThermoBarCore", linkerSettings: [.linkedFramework("IOKit")]),
        .testTarget(name: "ThermoBarCoreTests", dependencies: ["ThermoBarCore"])
    ],
    swiftLanguageModes: [.v6]
)
