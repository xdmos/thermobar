// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ThermoBar",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "ThermoBar", targets: ["ThermoBar"])],
    targets: [
        .target(name: "ThermoBarCore", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(
            name: "ThermoBar",
            dependencies: ["ThermoBarCore"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(name: "ThermoBarCoreTests", dependencies: ["ThermoBarCore"]),
        .testTarget(name: "ThermoBarAppTests", dependencies: ["ThermoBar", "ThermoBarCore"])
    ],
    swiftLanguageModes: [.v6]
)
