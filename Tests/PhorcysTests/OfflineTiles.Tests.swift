// Pins the tile arithmetic a chart download runs on: how much ground a tile
// covers, and which tiles a corridor along a route touches.
//
// The corridor is the whole point — a rectangle around a long passage is mostly
// water nobody will look at — so what these check above all is that it stays
// far smaller than the box, and that nothing along the route is missed.

import Stheno
import Testing

@testable import Phorcys

@Suite("Offline tiles")
struct OfflineTilesTests {

	/// Monaco to the Maddalena, roughly: a passage long enough that a bounding
	/// box and a corridor part company.
	private let passage = [
		Coordinate(latitude: 43.73, longitude: 7.42),
		Coordinate(latitude: 42.50, longitude: 8.80),
		Coordinate(latitude: 41.21, longitude: 9.40),
	]

	// MARK: Ground cover

	@Test("A tile's ground width halves with every zoom level")
	func widthHalvesPerZoom() {
		let eight = OfflineTiles.tileWidthNM(z: 8, latitude: 0)
		let nine = OfflineTiles.tileWidthNM(z: 9, latitude: 0)
		#expect(abs(eight / nine - 2) < 1e-9)
	}

	@Test("At the equator a zoom-zero tile is the whole circumference")
	func widthAtEquator() {
		#expect(abs(OfflineTiles.tileWidthNM(z: 0, latitude: 0) - 360 * 60) < 1e-6)
	}

	@Test("A tile covers less ground the further from the equator")
	func widthShrinksWithLatitude() {
		let equator = OfflineTiles.tileWidthNM(z: 10, latitude: 0)
		let mediterranean = OfflineTiles.tileWidthNM(z: 10, latitude: 43)
		#expect(mediterranean < equator)
		// cos 60° is a half, exactly.
		#expect(abs(OfflineTiles.tileWidthNM(z: 10, latitude: 60) / equator - 0.5) < 1e-9)
	}

	// MARK: The corridor

	@Test("A route of fewer than two points asks for nothing")
	func needsTwoPoints() {
		#expect(OfflineTiles.tiles(along: [Coordinate](), widthNM: 20, zooms: 8...10).isEmpty)
		#expect(OfflineTiles.tiles(along: [passage[0]], widthNM: 20, zooms: 8...10).isEmpty)
	}

	@Test("A corridor of no width asks for nothing")
	func needsAWidth() {
		#expect(OfflineTiles.tiles(along: passage, widthNM: 0, zooms: 8...10).isEmpty)
	}

	@Test("A wider corridor never asks for fewer tiles")
	func widerAsksForMore() {
		let narrow = OfflineTiles.tileCount(along: passage, widthNM: 5, zooms: 10...10)
		let wide = OfflineTiles.tileCount(along: passage, widthNM: 40, zooms: 10...10)
		#expect(wide > narrow)
	}

	@Test("Every zoom level adds its own tiles")
	func zoomsAccumulate() {
		let one = OfflineTiles.tileCount(along: passage, widthNM: 20, zooms: 10...10)
		let three = OfflineTiles.tileCount(along: passage, widthNM: 20, zooms: 8...10)
		#expect(three > one)
		// Each level is its own grid, so no tile of one is a tile of another.
		let all = OfflineTiles.tiles(along: passage, widthNM: 20, zooms: 8...10)
		#expect(Set(all.map(\.z)) == [8, 9, 10])
	}

	@Test("The corridor is far smaller than the box the passage sits in")
	func corridorBeatsBoundingBox() {
		// This is what makes the close zooms affordable: the same cover for a
		// fraction of the tiles.
		let z = 11
		let corridor = OfflineTiles.tileCount(along: passage, widthNM: 20, zooms: z...z)
		let corners = passage.map { OfflineTiles.tilePoint($0, z: z) }
		let xs = corners.map(\.x)
		let ys = corners.map(\.y)
		let box =
			(Int(xs.max()!) - Int(xs.min()!) + 1) * (Int(ys.max()!) - Int(ys.min()!) + 1)
		#expect(corridor < box / 2)
	}

	@Test("Every point of the route falls in a tile the corridor holds")
	func routeIsCovered() {
		// A corridor that stepped over a tile would leave a hole on the chart
		// exactly where the boat is going.
		let z = 11
		let tiles = OfflineTiles.tiles(along: passage, widthNM: 10, zooms: z...z)
		for point in passage {
			let here = OfflineTiles.tilePoint(point, z: z)
			let index = TileIndex(z: z, x: Int(here.x.rounded(.down)), y: Int(here.y.rounded(.down)))
			#expect(tiles.contains(index))
		}
	}

	@Test("Tiles never fall outside the grid")
	func staysInsideTheGrid() {
		// A route hard against the antimeridian would otherwise ask for a
		// column that does not exist.
		let z = 6
		let limit = 1 << z
		let edge = [
			Coordinate(latitude: 0, longitude: 179.9),
			Coordinate(latitude: 1, longitude: 179.99),
		]
		for tile in OfflineTiles.tiles(along: edge, widthNM: 60, zooms: z...z) {
			#expect(tile.x >= 0 && tile.x < limit)
			#expect(tile.y >= 0 && tile.y < limit)
		}
	}

	@Test("The count is the number of distinct tiles")
	func countMatchesSet() {
		let tiles = OfflineTiles.tiles(along: passage, widthNM: 20, zooms: 9...10)
		#expect(OfflineTiles.tileCount(along: passage, widthNM: 20, zooms: 9...10) == tiles.count)
	}
}
