// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "HubrisVoiceReleaseTool",
  platforms: [
    .macOS(.v15),
  ],
  products: [
    .executable(name: "hubris-voice-release", targets: ["HubrisVoiceReleaseTool"]),
  ],
  targets: [
    .target(name: "ReleaseToolCore"),
    .executableTarget(
      name: "HubrisVoiceReleaseTool",
      dependencies: ["ReleaseToolCore"]
    ),
    .testTarget(
      name: "ReleaseToolCoreTests",
      dependencies: ["ReleaseToolCore"]
    ),
  ]
)
