// swift-tools-version: 6.0
import PackageDescription

// TetrixHostKit is the client side of the host protocol. An app adds this
// package, pairs with a host once, and then sends its model requests through
// the sealed tunnel. It depends on Foundation and CryptoKit only.
let package = Package(
	name: "TetrixHostKit",
	platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
	products: [
		.library(name: "TetrixHostKit", targets: ["TetrixHostKit"]),
	],
	targets: [
		.target(name: "TetrixHostKit", path: "Sources/TetrixHostKit"),
		.testTarget(
			name: "TetrixHostKitTests",
			dependencies: ["TetrixHostKit"],
			path: "Tests/TetrixHostKitTests",
			resources: [.copy("Fixtures")]
		),
	],
	swiftLanguageModes: [.v6]
)
