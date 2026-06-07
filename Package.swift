// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "NeuronSearchLabSDK",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
    .tvOS(.v15),
    .watchOS(.v8),
  ],
  products: [
    .library(
      name: "NeuronSearchLabSDK",
      targets: ["NeuronSearchLab"]
    ),
  ],
  targets: [
    .target(name: "NeuronSearchLab"),
    .testTarget(
      name: "NeuronSearchLabTests",
      dependencies: ["NeuronSearchLab"]
    ),
  ]
)
