// swift-tools-version: 6.1

import PackageDescription

// The native bridge for non-Swift hosts (P/Invoke, ctypes, JNI…): Phorcys
// compiled into one dynamic library exposing a C ABI — the collision watch's
// arithmetic and the logbook roll's layout. A nested package so the main
// library product and its consumers are untouched; build it with
// `swift build -c release` from this directory.
let package = Package(
	name: "PhorcysBridge",
	platforms: [.macOS(.v15)],
	products: [
		.library(name: "PhorcysBridge", type: .dynamic, targets: ["PhorcysBridge"])
	],
	dependencies: [
		.package(path: "..")
	],
	targets: [
		.target(
			name: "PhorcysBridge",
			dependencies: [.product(name: "Phorcys", package: "Phorcys")],
			swiftSettings: [
				.enableUpcomingFeature("InternalImportsByDefault"),
				.enableUpcomingFeature("ExistentialAny"),
				.swiftLanguageMode(.v6),
			]
		)
	]
)
