// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlimeFactory",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "SlimeFactory",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/SlimeFactory",
            resources: [.copy("Resources/AppIcon.png")],
            swiftSettings: [.unsafeFlags(["-Ounchecked"])]
        )
    ]
)
