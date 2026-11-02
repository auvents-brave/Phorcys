// Exercises the land-avoiding router against a synthetic island, so the shapes
// are known exactly: open water gives a straight hop, an island in the way
// gives a detour that never crosses it, and a start left on the beach is pushed
// out to sea.
//
// Ported from the Apple app, where this search used to live, so the companion
// plans the same routes instead of growing one of its own.

import Foundation
import Stheno
import Testing

@testable import Phorcys

@Suite("Coastal router")
struct CoastalRouterTests {

	/// A square island spanning 0°–1° in both latitude and longitude, written as
	/// the loader expects to find it.
	private func island(in directory: URL) throws {
		let ring = "[[0,0],[1,0],[1,1],[0,1],[0,0]]"
		let geoJSON = """
			{ "type": "FeatureCollection", "features": [
			  { "type": "Feature", "geometry": { "type": "Polygon", "coordinates": [\(ring)] } }
			] }
			"""
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data(geoJSON.utf8).write(to: directory.appending(path: "CoastalLand.geojson"))
	}

	/// A router reading a freshly written island.
	private func router() throws -> CoastalRouter {
		let directory = URL.temporaryDirectory.appending(path: "phorcys-routing-\(UUID().uuidString)")
		try island(in: directory)
		return CoastalRouter(timeout: .seconds(30), dataDirectory: { directory })
	}

	/// Whether any leg of `route` passes over the island.
	private func crossesIsland(_ route: [Coordinate]) -> Bool {
		// Sample each leg densely rather than trusting the endpoints: a leg can
		// clear both ends and still cut a corner of the island.
		for (from, to) in zip(route, route.dropFirst()) {
			for step in 0...50 {
				let t = Double(step) / 50
				let point = from.interpolated(towards: to, fraction: t)
				if point.latitude > 0.001, point.latitude < 0.999,
					point.longitude > 0.001, point.longitude < 0.999
				{
					return true
				}
			}
		}
		return false
	}

	@Test("Open water gives a single straight leg")
	func openWaterIsDirect() async throws {
		let route = try await router().calculateRoute(
			from: Coordinate(latitude: 3.0, longitude: 3.0),
			to: Coordinate(latitude: 3.0, longitude: 4.0)
		)
		#expect(route.count == 2)
	}

	@Test("An island in the way is routed around, not through")
	func islandIsAvoided() async throws {
		let west = Coordinate(latitude: 0.5, longitude: -0.5)
		let east = Coordinate(latitude: 0.5, longitude: 1.5)
		let route = try await router().calculateRoute(from: west, to: east)

		#expect(route.count > 2)
		#expect(!crossesIsland(route))
		#expect(route.first?.longitude == west.longitude)
		#expect(route.last?.longitude == east.longitude)
	}

	@Test("A start point on land is moved out to open water")
	func landlockedStartIsSnapped() async throws {
		// Just inland of the west coast, with open water straight ahead.
		let onLand = Coordinate(latitude: 0.5, longitude: 0.05)
		let atSea = Coordinate(latitude: 0.5, longitude: -1.0)
		let route = try await router().calculateRoute(from: onLand, to: atSea)

		let start = try #require(route.first)
		#expect(start != onLand)
		#expect(!crossesIsland(route))
	}

	@Test("A snapped start still has to get round the island")
	func landlockedStartRoutesAround() async throws {
		// Known limitation, kept visible rather than deleted: a start snapped to
		// within half a nautical mile of the coast cannot join the visibility
		// graph, so a detour it should find comes back as `noRouteFound`. The
		// same pair of points routes fine when the start begins well offshore,
		// which is why `islandIsAvoided` passes. Leaving a harbour for a
		// destination on the far side of a headland therefore fails today.
		try await withKnownIssue("Shore-hugging start cannot join the visibility graph") {
			let onLand = Coordinate(latitude: 0.5, longitude: 0.05)
			let atSea = Coordinate(latitude: 0.5, longitude: 2.0)
			let route = try await router().calculateRoute(from: onLand, to: atSea)

			#expect(route.count > 2)
			#expect(!crossesIsland(route))
		}
	}

	@Test("A missing dataset is reported, not guessed around")
	func missingDataIsReported() async {
		let empty = URL.temporaryDirectory.appending(path: "phorcys-absent-\(UUID().uuidString)")
		let router = CoastalRouter(dataDirectory: { empty })

		await #expect(throws: CoastalRouter.RoutingError.self) {
			_ = try await router.calculateRoute(
				from: Coordinate(latitude: 3, longitude: 3),
				to: Coordinate(latitude: 3, longitude: 4)
			)
		}
	}
}
