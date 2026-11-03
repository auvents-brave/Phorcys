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

	/// The same island written twice over, as the coastline as first published carried
	/// Corsica and Elba: the coarse `ne_10m` ring, and a high-detail OSM outline
	/// merged on top of it. The two disagree slightly along the shore and are wound
	/// opposite ways, exactly as that data had them.
	private func doublyDrawnIsland(in directory: URL) throws {
		let coarse = "[[0,0],[1,0],[1,1],[0,1],[0,0]]"
		let detailed = "[[0.02,0.02],[0.02,1.02],[1.02,1.02],[1.02,0.02],[0.02,0.02]]"
		let geoJSON = """
			{ "type": "FeatureCollection", "features": [
			  { "type": "Feature", "geometry": { "type": "Polygon", "coordinates": [\(coarse)] } },
			  { "type": "Feature", "geometry": { "type": "Polygon", "coordinates": [\(detailed)] } }
			] }
			"""
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data(geoJSON.utf8).write(to: directory.appending(path: "CoastalLand.geojson"))
	}

	/// A directory holding one of the fixtures above, and a detector over it.
	private func fixture(_ write: (URL) throws -> Void) throws -> (URL, LandDetector) {
		let directory = URL.temporaryDirectory.appending(path: "phorcys-routing-\(UUID().uuidString)")
		try write(directory)
		return (directory, LandDetector(data: try CoastalDataLoader.load(from: directory)))
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
		// Leaving a harbour for a destination on the far side of the land: the start
		// is snapped out to sea and then still has to be routed the long way round.
		// A start held only just clear of the shore has no first leg at all — every
		// one of them grazes the coast — so snapping keeps it a nautical mile or so
		// offshore, like the graph's own nodes.
		let onLand = Coordinate(latitude: 0.5, longitude: 0.05)
		let atSea = Coordinate(latitude: 0.5, longitude: 2.0)
		let route = try await router().calculateRoute(from: onLand, to: atSea)

		#expect(route.count > 2)
		#expect(!crossesIsland(route))
		let start = try #require(route.first)
		#expect(start.longitude < 0)
	}

	@Test("An island the data draws twice is still land all the way through")
	func doublyDrawnIslandIsSolid() throws {
		// Counting the ray crossings in one pooled even-odd tally lets two outlines of
		// one island cancel, so everything inland reads as open water and only the
		// sliver where the outlines disagree reads as land. That hollowed out Corsica
		// and Elba on the coastline as first published, and an endpoint ashore was then
		// snapped into the middle of the island, where no leg reaches the sea. The data
		// has since been de-duplicated, which leaves this test as the guard: the
		// semantics have to hold whatever the data does next.
		let (_, detector) = try fixture(doublyDrawnIsland(in:))

		#expect(detector.isLand(Coordinate(latitude: 0.5, longitude: 0.5)))  // inside both outlines
		#expect(detector.isLand(Coordinate(latitude: 0.01, longitude: 0.5)))  // the coarse one only
		#expect(detector.isLand(Coordinate(latitude: 1.01, longitude: 0.5)))  // the detailed one only
		#expect(!detector.isLand(Coordinate(latitude: 0.5, longitude: 2.0)))  // open water
	}

	@Test("A harbour on a doubly drawn island still gets out to sea")
	func harbourOnDoublyDrawnIslandRoutes() async throws {
		let directory = URL.temporaryDirectory.appending(path: "phorcys-routing-\(UUID().uuidString)")
		try doublyDrawnIsland(in: directory)
		let router = CoastalRouter(timeout: .seconds(30), dataDirectory: { directory })

		// A berth just inside the eastern shore, as Bastia sits on Corsica's.
		let harbour = Coordinate(latitude: 0.5, longitude: 0.99)
		let atSea = Coordinate(latitude: 0.5, longitude: 2.5)
		let route = try await router.calculateRoute(from: harbour, to: atSea)

		let detector = LandDetector(data: try CoastalDataLoader.load(from: directory))
		let start = try #require(route.first)
		#expect(!detector.isLand(start))
		#expect(start.longitude > 1.02)  // out past the seaward outline, not inland
		for (from, to) in zip(route, route.dropFirst()) {
			#expect(!detector.segmentCrossesLand(from: from, to: to))
		}
	}

	@Test("A berth too close in to leave is moved out to where it can be")
	func crampedSeaEndpointIsMovedOut() async throws {
		// At sea, but a tenth of a mile off the west coast. Every leg from here has
		// land inside the grazing clearance on one side or the other, so until an
		// endpoint was given sea room whatever it read as, this came back as
		// `noRouteFound`. Real harbour water fails this way too: at Toulon the coarse
		// coastline is drawn inland of the real shore and wanders across the port, so
		// the Vieux-Port reads as sea while being penned into a pocket a mile or two
		// wide that no leg can leave.
		let berth = Coordinate(latitude: 0.5, longitude: -0.002)
		let atSea = Coordinate(latitude: 0.5, longitude: 2.0)
		let route = try await router().calculateRoute(from: berth, to: atSea)

		let start = try #require(route.first)
		#expect(berth.distanceNauticalMiles(to: start) >= 1.0)
		#expect(route.count > 2)
		#expect(!crossesIsland(route))
	}

	@Test("The sea-leg test agrees with the general one wherever both ends are at sea")
	func seaLegTestMatchesTheGeneralOne() throws {
		// The router asks ``LandDetector/seaLegCrossesLand(from:to:)`` of every leg it
		// considers, which skips the endpoint containment test — by far the most
		// expensive part — on the grounds that it can only ever answer `false` for the
		// at-sea nodes the graph is built from. That equivalence is what makes the
		// search tractable, so pin it down over a grid of legs: clear water, legs that
		// cut a corner, legs that graze the shore, legs straight across the island.
		let (_, detector) = try fixture(island(in:))
		var points: [Coordinate] = []
		for latitude in stride(from: -0.5, through: 1.5, by: 0.1) {
			for longitude in stride(from: -0.5, through: 1.5, by: 0.1) {
				points.append(Coordinate(latitude: latitude, longitude: longitude))
			}
		}
		let atSea = points.filter { !detector.isLand($0) }
		#expect(atSea.count > 100)

		var disagreements = 0
		for from in atSea {
			for to in atSea where from != to {
				if detector.seaLegCrossesLand(from: from, to: to)
					!= detector.segmentCrossesLand(from: from, to: to)
				{
					disagreements += 1
				}
			}
		}
		#expect(disagreements == 0)
	}

	@Test("A leg that never leaves the land is caught by the endpoint test alone")
	func inlandLegNeedsTheEndpointTest() throws {
		// The other side of the same coin, and the reason both tests exist: a leg
		// wholly inland crosses no shore, so only containment can condemn it. The
		// cheaper test is therefore only safe for endpoints already known to be at
		// sea, as the graph's nodes and the snapped endpoints are.
		let (_, detector) = try fixture(island(in:))
		let from = Coordinate(latitude: 0.25, longitude: 0.25)
		let to = Coordinate(latitude: 0.75, longitude: 0.75)

		#expect(detector.isLand(from))
		#expect(detector.segmentCrossesLand(from: from, to: to))
		#expect(!detector.seaLegCrossesLand(from: from, to: to))
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
