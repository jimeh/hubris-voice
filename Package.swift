// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "HubrisVoice",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "HubrisVoiceCore", targets: ["HubrisVoiceCore"]),
    .executable(name: "HubrisVoice", targets: ["HubrisVoiceApp"]),
  ],
  targets: [
    .target(name: "HubrisVoiceCore"),
    .executableTarget(
      name: "HubrisVoiceApp",
      dependencies: ["HubrisVoiceCore"]
    ),
    .testTarget(
      name: "HubrisVoiceCoreTests",
      dependencies: ["HubrisVoiceCore"]
    ),
    .testTarget(
      name: "HubrisVoiceAppTests",
      dependencies: ["HubrisVoiceApp"]
    ),
  ]
)
