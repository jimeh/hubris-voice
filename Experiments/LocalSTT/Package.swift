// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LocalSTTExperiment",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7"),
  ],
  targets: [
    .executableTarget(name: "LocalSTTExperiment", dependencies: ["FluidAudio"]),
    .executableTarget(name: "CacheIsolationProbe", dependencies: ["FluidAudio"]),
  ]
)
