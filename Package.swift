// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OllaCoreMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OllaCoreMac", targets: ["OllaCoreMac"])],
    targets: [.executableTarget(name: "OllaCoreMac", path: "Sources"), .testTarget(name: "OllaCoreMacTests", dependencies: ["OllaCoreMac"], path: "Tests/OllaCoreMacTests")]
)
