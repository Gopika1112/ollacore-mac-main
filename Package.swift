// swift-tools-version: 5.9
import PackageDescription

// NOTE: native WebRTC (libwebrtc) intentionally NOT linked yet — no verified
// SwiftPM package + media integration on this Windows box. To enable calls:
// add e.g. `.package(url: "https://github.com/stasel/WebRTC.git", from: "...")`
// and bind RtcWebSocket ↔ RTCPeerConnection in CallScreenView.
// MLS likewise: add OpenMLS/libmls + keypackage directory once backend ships;
// E2EEStub.rotateEpoch/safetyNumber are the integration points.
let package = Package(
    name: "OllaCoreMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OllaCoreMac", targets: ["OllaCoreMac"])],
    targets: [.executableTarget(name: "OllaCoreMac", path: "Sources"), .testTarget(name: "OllaCoreMacTests", dependencies: ["OllaCoreMac"], path: "Tests/OllaCoreMacTests")]
)
