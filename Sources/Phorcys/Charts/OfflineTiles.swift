import Foundation

public import Stheno

/// Which tiles a passage needs, so they can be fetched before leaving the
/// network behind.
///
/// A rectangle around a long passage is mostly water nobody will look at: the
/// corridor along the route is several times smaller for the same cover, which
/// is what makes the close zoom levels affordable at all. It also bounds the
/// request by construction — there is no way to ask for a whole sea.
///
/// Pure geometry, with no tile source or cache behind it, so the counts can be
/// checked without the network — and so every app that offers the download
/// asks for the same tiles.
public enum OfflineTiles {

	/// The Earth's circumference in nautical miles, one minute of arc to the
	/// mile by definition.
	private static let circumferenceNM: Double = 360 * 60

	/// How wide one tile is on the ground, in nautical miles.
	///
	/// Web Mercator is conformal, so a tile covers the same ground distance
	/// east-west as north-south at a given latitude — which is why the corridor
	/// radius below is a plain circle in tile units.
	///
	/// - Parameters:
	///   - z: The zoom level.
	///   - latitude: Where on the Earth, in degrees.
	/// - Returns: The tile's ground width in nautical miles.
	public static func tileWidthNM(z: Int, latitude: Double) -> Double {
		circumferenceNM * cos(latitude * .pi / 180) / pow(2, Double(z))
	}

	/// The tile coordinates of a position, with their fractional part — the
	/// whole part is the tile it falls in, the fraction where inside it.
	static func tilePoint(_ coordinate: Coordinate, z: Int) -> (x: Double, y: Double) {
		let n = pow(2, Double(z))
		let latitude = min(max(coordinate.latitude, -85.051_128), 85.051_128) * .pi / 180
		let x = (coordinate.longitude + 180) / 360 * n
		let y = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2 * n
		return (x, y)
	}

	/// Every tile within `widthNM / 2` of the route, at each zoom in `zooms`.
	///
	/// - Parameters:
	///   - route: The passage, in order. Fewer than two points yields nothing.
	///   - widthNM: The corridor's full width, in nautical miles.
	///   - zooms: The zoom levels to cover.
	/// - Returns: The tiles to hold, with no duplicates.
	public static func tiles(
		along route: [Coordinate], widthNM: Double, zooms: ClosedRange<Int>
	) -> Set<TileIndex> {
		guard route.count >= 2, widthNM > 0 else { return [] }
		var found: Set<TileIndex> = []
		for z in zooms {
			let limit = Int(pow(2, Double(z)))
			for index in 0..<(route.count - 1) {
				mark(
					from: route[index], to: route[index + 1], widthNM: widthNM, z: z, limit: limit,
					into: &found)
			}
		}
		return found
	}

	/// How many tiles that corridor holds — the figure the download sheet shows
	/// before anything is fetched.
	///
	/// - Parameters:
	///   - route: The passage, in order.
	///   - widthNM: The corridor's full width, in nautical miles.
	///   - zooms: The zoom levels to cover.
	/// - Returns: The number of distinct tiles.
	public static func tileCount(
		along route: [Coordinate], widthNM: Double, zooms: ClosedRange<Int>
	) -> Int {
		tiles(along: route, widthNM: widthNM, zooms: zooms).count
	}

	/// Walks one leg, marking the tiles its corridor touches.
	///
	/// The leg is sampled at half a tile at a time so no tile is stepped over,
	/// and at each sample every tile whose centre falls inside the corridor
	/// radius is taken.
	private static func mark(
		from start: Coordinate, to end: Coordinate,
		widthNM: Double, z: Int, limit: Int, into found: inout Set<TileIndex>
	) {
		let first = tilePoint(start, z: z)
		let last = tilePoint(end, z: z)
		let span = (dx: last.x - first.x, dy: last.y - first.y)
		let legInTiles = (span.dx * span.dx + span.dy * span.dy).squareRoot()
		let steps = max(1, Int((legInTiles * 2).rounded(.up)))

		for step in 0...steps {
			let along = Double(step) / Double(steps)
			let here = (x: first.x + span.dx * along, y: first.y + span.dy * along)
			// The corridor's half width, measured in tiles at this latitude.
			let latitude = start.latitude + (end.latitude - start.latitude) * along
			let radius = widthNM / 2 / tileWidthNM(z: z, latitude: latitude)
			let reach = Int(radius.rounded(.up))

			for dx in -reach...reach {
				for dy in -reach...reach {
					let x = Int(here.x.rounded(.down)) + dx
					let y = Int(here.y.rounded(.down)) + dy
					guard x >= 0, y >= 0, x < limit, y < limit else { continue }
					// The tile's centre against the corridor's circle.
					let offset = (x: Double(x) + 0.5 - here.x, y: Double(y) + 0.5 - here.y)
					guard (offset.x * offset.x + offset.y * offset.y).squareRoot() <= radius + 0.75
					else { continue }
					found.insert(TileIndex(z: z, x: x, y: y))
				}
			}
		}
	}
}
