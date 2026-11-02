public import Foundation
public import Stheno

// The offline coastal router. Given two coordinates it returns an ordered list
// of waypoints that stays at sea, computed entirely from the downloaded Natural
// Earth polygons. Routing itself never touches the network; only the one-off
// dataset download does, through ``CoastalDataStore``.
//
// Strategy (see the feature brief):
//   1. Snap any land-locked endpoint out to the nearest open water.
//   2. If the direct leg is already clear, return it as a single hop.
//   3. Otherwise build a visibility graph from the nearby coastline vertices
//      (nudged just offshore), run A* over it with great-circle distance as the
//      heuristic, then string-pull the result to drop redundant waypoints.
//
// An `actor`, so the heavy work runs off the main actor; the loaded data is
// cached between calls.

/// Computes land-avoiding coastal routes from the downloaded coastline data.
public actor CoastalRouter {

	/// A failure producing a route.
	public enum RoutingError: Error {
		/// The coastline data could not be loaded.
		case dataUnavailable(any Error)
		/// An endpoint sits on land and no open water was found within range.
		case endpointLandlocked
		/// No land-free path could be found between the points.
		case noRouteFound
		/// The computation exceeded its time budget.
		case timedOut

		/// A plain-English description.
		///
		/// Deliberately unlocalised: `String(localized:)` does not exist in
		/// Foundation outside Darwin, and this library also runs on Linux,
		/// Windows and Android through the bridge. An app translates the cases
		/// itself — Thoôsa conforms this type to `LocalizedError` on its side.
		public var summary: String {
			switch self {
			case .dataUnavailable(let error):
				"The coastline data could not be loaded: \(error)"
			case .endpointLandlocked:
				"A start or end point is on land with no nearby open water."
			case .noRouteFound:
				"No sea route could be found between these points."
			case .timedOut:
				"Route planning took too long and was stopped."
			}
		}
	}

	/// How long a single route computation may run before giving up.
	private let timeout: Duration
	/// Resolves the directory the coastline data is loaded from, downloading it
	/// on first use. A closure rather than the store itself, so a test can point
	/// the router at a fixture without standing up a download.
	private let dataDirectory: @Sendable () async throws -> URL
	/// The loaded land detector, parsed once and cached.
	private var landDetector: LandDetector?

	/// Creates a router.
	/// - Parameters:
	///   - timeout: The per-route time budget (30 seconds by default).
	///   - dataDirectory: Resolves the directory holding the coastline GeoJSON.
	///     A closure, not a path: the caller owns how the data gets there —
	///     downloaded on an app's first use, shipped beside an executable, or a
	///     fixture in a test.
	public init(
		timeout: Duration = .seconds(30),
		dataDirectory: @escaping @Sendable () async throws -> URL
	) {
		self.timeout = timeout
		self.dataDirectory = dataDirectory
	}

	/// Loads (and caches) the coastline ahead of time, so the first real route
	/// does not pay the parse cost. Safe to call repeatedly.
	public func warmUp() async throws {
		_ = try await detector()
	}

	// MARK: Routing

	/// Computes a land-avoiding route between two coordinates.
	///
	/// - Parameters:
	///   - from: The start coordinate.
	///   - to: The destination coordinate.
	/// - Returns: An ordered list of waypoints (at least the start and end) that
	///   keeps to open water. A land-locked endpoint is snapped to the nearest
	///   sea point, so the returned ends may differ slightly from the inputs.
	/// - Throws: ``RoutingError`` when the data is unavailable, an endpoint cannot
	///   be reached, no route exists, or the time budget is exceeded.
	public func calculateRoute(
		from: Coordinate,
		to: Coordinate
	) async throws -> [Coordinate] {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: timeout)

		let start = from
		let end = to

		// Identical (or all-but-identical) points: nothing to route.
		if start.distanceNauticalMiles(to: end) < 0.01 {
			return [start]
		}

		let detector = try await detector()

		// 1. Snap land-locked endpoints out to open water.
		let seaStart = try snapToSea(start, using: detector, clock: clock, deadline: deadline)
		let seaEnd = try snapToSea(end, using: detector, clock: clock, deadline: deadline)

		// 2. Direct leg clear → single hop. (The orthodromic leg between the two
		//    points is exactly this straight line; ``Geo`` supplies its length.)
		if !detector.segmentCrossesLand(from: seaStart, to: seaEnd) {
			return [seaStart, seaEnd]
		}

		// 3. Visibility graph + A* + simplify. A detour around a large landmass can
		//    bulge well outside the direct line, so the search box starts at the
		//    feature brief's modest margin and is grown until a route is found (or
		//    it covers the whole dataset). This keeps the common case — a small box
		//    — fast while still solving routes around big obstacles.
		for marginFraction in Self.searchMargins {
			try checkDeadline(clock: clock, deadline: deadline)
			let nodes = visibilityNodes(
				start: seaStart, end: seaEnd, marginFraction: marginFraction, detector: detector)
			do {
				let path = try aStar(nodes: nodes, detector: detector, clock: clock, deadline: deadline)
				let simplified = simplify(path, detector: detector)
				return simplified
			} catch RoutingError.noRouteFound {
				continue  // grow the box and try again
			}
		}
		throw RoutingError.noRouteFound
	}

	/// Search-box margins, as fractions of the route's diagonal, tried in turn.
	/// The first (≈ the 20 % brief default) covers most coastal hops; the larger
	/// ones let a route wrap around a sizeable island or peninsula.
	private static let searchMargins: [Double] = [0.25, 0.75, 2.0, 5.0]

	/// Returns the land detector, loading and caching the coastline on first use.
	private func detector() async throws -> LandDetector {
		if let landDetector { return landDetector }
		do {
			let directory = try await dataDirectory()
			let detector = LandDetector(data: try CoastalDataLoader.load(from: directory))
			landDetector = detector
			return detector
		} catch {
			throw RoutingError.dataUnavailable(error)
		}
	}

	// MARK: Endpoint snapping

	/// Returns `point` if it is at sea, otherwise the nearest open-water point
	/// found by spiralling outward in rings of increasing radius.
	private func snapToSea(
		_ point: Coordinate,
		using detector: LandDetector,
		clock: ContinuousClock,
		deadline: ContinuousClock.Instant
	) throws -> Coordinate {
		guard detector.isLand(point) else { return point }

		let stepNm = 0.5
		let maxNm = 60.0
		var radius = stepNm
		while radius <= maxNm {
			try checkDeadline(clock: clock, deadline: deadline)
			for bearing in stride(from: 0.0, to: 360.0, by: 15.0) {
				let candidate = point.destination(bearing: bearing, distanceNauticalMiles: radius)
				if !detector.isLand(candidate) { return candidate }
			}
			radius += stepNm
		}
		throw RoutingError.endpointLandlocked
	}

	// MARK: Visibility graph

	/// Builds the graph nodes: the start and end, plus the coastline vertices
	/// inside the route's (20 %-grown) bounding box, each nudged just offshore so
	/// edges to it run through water rather than grazing the coast.
	private func visibilityNodes(
		start: Coordinate, end: Coordinate, marginFraction: Double, detector: LandDetector
	) -> [Coordinate] {
		guard let baseBox = GeoBoundingBox(points: [start, end]) else { return [start, end] }
		// Margin in degrees: a fraction of the route diagonal, with a floor so even
		// a short hop still admits a small detour.
		let margin = max(baseBox.diagonalDegrees * marginFraction, 0.3)
		let routeBox = baseBox.expandedByDegrees(margin)

		var nodes: [Coordinate] = [start, end]
		var seen = Set<Coordinate>([rounded(start), rounded(end)])

		// Only keep obstacles within `margin` of the *direct line*, not the whole
		// bounding box. For a long leg the box is enormous and mostly far from the
		// route, so this corridor cuts the graph (A* is O(n²)) without losing any
		// detour the margin already allows; growing the margin widens the corridor.
		func inCorridor(_ point: Coordinate) -> Bool {
			distanceToLineDegrees(point, start, end) <= margin
		}

		for polygon in detector.data.polygons where polygon.boundingBox.intersects(routeBox) {
			let points = polygon.points
			let count = points.count
			for index in points.indices where routeBox.contains(points[index]) && inCorridor(points[index]) {
				let previous = points[(index + count - 1) % count]
				let next = points[(index + 1) % count]
				for offshore in offshoreNudges(points[index], previous: previous, next: next, detector: detector) {
					let key = rounded(offshore)
					if seen.insert(key).inserted { nodes.append(offshore) }
				}
			}
		}

		// High-precision tile coastlines carry capes and inlets the coarse polygons
		// smooth away (Cap d'Antibes is barely a bump in `ne_10m`). Without nodes
		// here, A* can't round those features tightly and detours far out to sea, so
		// nudge their corridor vertices offshore exactly like the ring vertices.
		for line in detector.data.coastlines {
			let count = line.count
			guard count >= 2 else { continue }
			for index in line.indices where routeBox.contains(line[index]) && inCorridor(line[index]) {
				let previous = line[Swift.max(index - 1, 0)]
				let next = line[Swift.min(index + 1, count - 1)]
				guard previous != next else { continue }
				for offshore in offshoreNudges(line[index], previous: previous, next: next, detector: detector) {
					let key = rounded(offshore)
					if seen.insert(key).inserted { nodes.append(offshore) }
				}
			}
		}

		// A small island (Giraglia, a rock) is narrower than the offshore offset, so
		// the per-vertex nudging above finds no clear seaward side and adds no nodes
		// — leaving A* nothing to route *around* it. Give every small feature in the
		// box a ring of detour nodes just offshore. Large landmasses are skipped:
		// their coastline vertices already nudge cleanly.
		for polygon in detector.data.polygons where polygon.boundingBox.intersects(routeBox) {
			let box = polygon.boundingBox
			guard box.diagonalDegrees < Self.smallIslandMaxDegrees else { continue }
			let centre = Coordinate(
				latitude: (box.minLatitude + box.maxLatitude) / 2,
				longitude: (box.minLongitude + box.maxLongitude) / 2)
			guard inCorridor(centre) else { continue }
			// Half the island's diagonal (degrees → nm) plus an offshore margin.
			let radiusNm = box.diagonalDegrees * 30 + Self.offshoreMarginNm
			for bearing in stride(from: 0.0, to: 360.0, by: 45.0) {
				let candidate = centre.destination(bearing: bearing, distanceNauticalMiles: radiusNm)
				guard !detector.isLand(candidate) else { continue }
				let key = rounded(candidate)
				if seen.insert(key).inserted { nodes.append(candidate) }
			}
		}

		// Keep the graph bounded: if a busy area yields too many vertices,
		// *uniformly* subsample the extras (never by proximity to the direct line —
		// the detour nodes that round a large obstacle are precisely the ones
		// farthest from it). Uniform sampling preserves the coastline's shape, so a
		// way around still exists; it may just round a cape a touch wide.
		if nodes.count > Self.maxNodes {
			let fixed = Array(nodes.prefix(2))
			let extras = Array(nodes.dropFirst(2))
			let stride = Int((Double(extras.count) / Double(Self.maxNodes - 2)).rounded(.up))
			let sampled =
				stride <= 1 ? extras : extras.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
			nodes = fixed + sampled
		}
		return nodes
	}

	/// Offsets a coastline vertex a short way out to sea, perpendicular to its two
	/// adjacent edges, and returns whichever of the two sides are clear water.
	///
	/// For a closed ring exactly one side is sea, so this returns a single node. At
	/// a cape tip or inlet — or wherever the coarse rings disagree with a precise
	/// tile coastline — both offsets can read as sea; rather than give up (which
	/// would leave A* no way around the feature), both are returned. A node on the
	/// wrong side is harmless: every leg to or from it is still land-tested, so the
	/// precise crossing check discards any that cuts the coast.
	private func offshoreNudges(
		_ vertex: Coordinate, previous: Coordinate, next: Coordinate, detector: LandDetector
	) -> [Coordinate] {
		// Tangent through the vertex, in an equirectangular frame scaled by the
		// local latitude so the offset is roughly distance-true.
		let cosLat = cos(vertex.latitude * .pi / 180)
		let tx = (next.longitude - previous.longitude) * cosLat
		let ty = next.latitude - previous.latitude
		let length = (tx * tx + ty * ty).squareRoot()
		guard length > 0 else { return [] }

		// The two unit normals, scaled to the offshore offset, converted back to
		// degrees (undoing the cosine scaling on longitude). The offset clears the
		// coast clearance (≈ 0.5 nm) with room to spare, so coastal legs between
		// these nodes aren't themselves rejected for running too close.
		let offsetNm = 1.2
		let offsetDegrees = offsetNm / 60.0
		let nx = -ty / length
		let ny = tx / length
		let dLon = nx * offsetDegrees / max(cosLat, 0.000001)
		let dLat = ny * offsetDegrees

		let plus = Coordinate(latitude: vertex.latitude + dLat, longitude: vertex.longitude + dLon)
		let minus = Coordinate(latitude: vertex.latitude - dLat, longitude: vertex.longitude - dLon)
		return [plus, minus].filter { !detector.isLand($0) }
	}

	// MARK: A*

	/// Runs A* from node 0 (start) to node 1 (end) over the visibility graph,
	/// generating each node's visible neighbours lazily.
	private func aStar(
		nodes: [Coordinate],
		detector: LandDetector,
		clock: ContinuousClock,
		deadline: ContinuousClock.Instant
	) throws -> [Coordinate] {
		let startIndex = 0
		let goalIndex = 1
		let goal = nodes[goalIndex]

		var gScore = [Double](repeating: .infinity, count: nodes.count)
		var fScore = [Double](repeating: .infinity, count: nodes.count)
		var cameFrom = [Int](repeating: -1, count: nodes.count)
		var closed = [Bool](repeating: false, count: nodes.count)
		gScore[startIndex] = 0
		fScore[startIndex] = nodes[startIndex].distanceKilometres(to: goal)

		// Bucket node indices into a coarse grid so each node only land-tests its
		// *local* neighbours (plus the goal), not all n nodes — the O(n²) all-pairs
		// land check is what blew the time budget on long legs. Long open-water
		// hops are recovered afterwards by `simplify`'s string-pull.
		let cell = Self.neighbourCellDegrees
		func cellKey(_ point: Coordinate) -> Int {
			let column = Int((point.longitude / cell).rounded(.down)) + 4000
			let row = Int((point.latitude / cell).rounded(.down)) + 4000
			return column &* 100_000 &+ row
		}
		var buckets: [Int: [Int]] = [:]
		for index in nodes.indices { buckets[cellKey(nodes[index]), default: []].append(index) }
		func neighbours(of index: Int) -> [Int] {
			let point = nodes[index]
			let column = Int((point.longitude / cell).rounded(.down)) + 4000
			let row = Int((point.latitude / cell).rounded(.down)) + 4000
			var result = [goalIndex]
			for dColumn in -1...1 {
				for dRow in -1...1 {
					if let bucket = buckets[(column + dColumn) &* 100_000 &+ (row + dRow)] { result += bucket }
				}
			}
			return result
		}

		var open = Set([startIndex])

		while let current = open.min(by: { fScore[$0] < fScore[$1] }) {
			try checkDeadline(clock: clock, deadline: deadline)
			if current == goalIndex {
				return reconstruct(cameFrom: cameFrom, from: goalIndex, nodes: nodes)
			}
			open.remove(current)
			closed[current] = true

			for neighbour in neighbours(of: current) where !closed[neighbour] && neighbour != current {
				// The leg must be clear of land (the goal is always a candidate, so the
				// final hop is considered even when it is far from `current`).
				if detector.segmentCrossesLand(from: nodes[current], to: nodes[neighbour]) { continue }
				let tentative = gScore[current] + nodes[current].distanceKilometres(to: nodes[neighbour])
				if tentative < gScore[neighbour] {
					cameFrom[neighbour] = current
					gScore[neighbour] = tentative
					fScore[neighbour] = tentative + nodes[neighbour].distanceKilometres(to: goal)
					open.insert(neighbour)
				}
			}
		}
		throw RoutingError.noRouteFound
	}

	/// Walks the `cameFrom` chain back from the goal into an ordered waypoint list.
	private func reconstruct(cameFrom: [Int], from goalIndex: Int, nodes: [Coordinate]) -> [Coordinate] {
		var path: [Coordinate] = []
		var index = goalIndex
		while index != -1 {
			path.append(nodes[index])
			index = cameFrom[index]
		}
		return path.reversed()
	}

	// MARK: Simplification

	/// String-pulls the path: walks from each kept waypoint as far ahead as the
	/// straight leg stays clear of land, dropping the waypoints in between.
	private func simplify(_ path: [Coordinate], detector: LandDetector) -> [Coordinate] {
		guard path.count > 2 else { return path }
		var result = [path[0]]
		var anchor = 0
		while anchor < path.count - 1 {
			var farthest = anchor + 1
			for candidate in (anchor + 2)..<path.count {
				if detector.segmentCrossesLand(from: path[anchor], to: path[candidate]) { break }
				farthest = candidate
			}
			result.append(path[farthest])
			anchor = farthest
		}
		return result
	}

	// MARK: Helpers

	/// Throws ``RoutingError/timedOut`` once the deadline has passed.
	private func checkDeadline(clock: ContinuousClock, deadline: ContinuousClock.Instant) throws {
		if clock.now >= deadline { throw RoutingError.timedOut }
	}

	/// Distance, in degrees (matching ``GeoBoundingBox/diagonalDegrees`` and the
	/// margin), from `point` to the segment `a`→`b` — the route's direct line.
	private func distanceToLineDegrees(_ point: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Double {
		let dx = b.longitude - a.longitude
		let dy = b.latitude - a.latitude
		let px = point.longitude - a.longitude
		let py = point.latitude - a.latitude
		let lengthSquared = dx * dx + dy * dy
		guard lengthSquared > 0 else { return (px * px + py * py).squareRoot() }
		let t = max(0, min(1, (px * dx + py * dy) / lengthSquared))
		let cx = px - t * dx
		let cy = py - t * dy
		return (cx * cx + cy * cy).squareRoot()
	}

	/// A vertex key snapped to a ~1 nm grid. Beyond de-duplicating offshore nodes
	/// it *decimates* them: a detailed coast (a dense OSM island, or a precise tile
	/// coastline) yields at most one graph node per cell, keeping the O(n²) search
	/// tractable. One node per nautical mile is ample at routing scale — legs sit
	/// 1.2 nm offshore and `simplify` string-pulls the rounded path straight — and
	/// without it an indented coast (southern Corsica) floods the graph with
	/// thousands of nodes and A* times out.
	private func rounded(_ point: Coordinate) -> Coordinate {
		Coordinate(
			latitude: (point.latitude * 60).rounded() / 60,
			longitude: (point.longitude * 60).rounded() / 60
		)
	}

	/// Upper bound on visibility-graph nodes, to keep A* responsive in dense
	/// archipelagos. High enough to keep the coastline's shape after subsampling,
	/// low enough that the O(n²) visibility expansion stays within the time budget.
	private static let maxNodes = 2000

	/// Grid cell (degrees, ≈ 60 nm) for A*'s neighbour lookup: each node only
	/// land-tests nodes in its own and the eight adjacent cells (plus the goal),
	/// so a leg can span up to ~two cells of open water; string-pulling then
	/// straightens longer open hops. Small enough to prune the O(n²) all-pairs
	/// land check, large enough to cross the Mediterranean's coastal straits.
	private static let neighbourCellDegrees = 1.0

	/// Features whose bounding-box diagonal is below this (≈ 18 nm) get a ring of
	/// detour nodes around them; larger landmasses rely on per-vertex nudging.
	private static let smallIslandMaxDegrees = 0.3

	/// How far offshore (nm) the small-island detour ring sits beyond the island.
	private static let offshoreMarginNm = 1.0
}
