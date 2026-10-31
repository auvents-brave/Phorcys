import Foundation
// swift-tools-version:6.1
import PackageDescription

let sharedSwiftSettings: [SwiftSetting] = [
	.swiftLanguageMode(.v6),
	.enableUpcomingFeature("ExistentialAny"),
	.enableUpcomingFeature("InternalImportsByDefault"),
]

// Siblings: use the local working copies during development, and resolve from
// GitHub when Phorcys is itself a checked-out dependency — a sibling checkout
// referenced by path would otherwise clash with a URL-based declaration in the
// consuming package ("conflicting identity").
var deps: [Package.Dependency] = []
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let siblingsRoot = packageDirectory.deletingLastPathComponent()
let isCheckout = siblingsRoot.lastPathComponent == "checkouts"
// Stheno alone: nothing here decodes NMEA or talks to a boat, so BoatToolsKit
// would only drag libcurl and swift-nio into a bridge that needs neither.
for (name, url) in [("Stheno", "https://github.com/auvents-brave/Stheno")] {
	let local = siblingsRoot.appendingPathComponent(name).path
	if !isCheckout, FileManager.default.fileExists(atPath: local) {
		deps.append(.package(path: local))
	} else {
		deps.append(.package(url: url, branch: "main"))
	}
}

let package = Package(
	name: "Phorcys",
	platforms: [
		.macOS(.v14), .macCatalyst(.v17), .iOS(.v17), .tvOS(.v17), .watchOS(.v11), .visionOS(.v1),
	],
	products: [
		.library(name: "Phorcys", targets: ["Phorcys"])
	],
	dependencies: deps,
	targets: [
		.target(
			name: "Phorcys",
			dependencies: [.product(name: "Stheno", package: "Stheno")],
			path: "Sources/Phorcys",
			swiftSettings: sharedSwiftSettings
		),
		.testTarget(
			name: "PhorcysTests",
			dependencies: ["Phorcys"],
			path: "Tests/PhorcysTests",
			swiftSettings: sharedSwiftSettings
		),
	]
)
