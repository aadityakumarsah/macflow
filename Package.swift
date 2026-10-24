// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FocusFlow",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FocusFlow", targets: ["FocusFlow"])],
    targets: [
        .executableTarget(
            name: "FocusFlow",
            path: "Sources/FocusFlow",
            resources: [.copy("BrowserRecorder"), .copy("Backgrounds")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
