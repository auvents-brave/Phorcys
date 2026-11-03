import Foundation
public import Stheno

// Point- and segment-versus-land tests against the loaded Natural Earth
// polygons. A value type (so it is trivially `Sendable` and callable from any
// isolation context); it only ever reads its immutable data.
//
// The land geometry is dominated by a few enormous rings (the Eurasian/African
// landmass alone is thousands of vertices), so a plain ring scan per query is
// far too slow for the thousands of visibility tests the router runs. Instead
// the detector indexes every polygon edge into a uniform lat/lon grid:
//
//   • `isLand` casts a ray due east and counts the edges it crosses, walking
//     only the grid row the point sits in.
//   • `segmentCrossesLand` walks just the grid cells the leg passes through
//     (a DDA traversal) and intersection-tests the handful of edges in each.
//
// Both costs scale with the local edge density, not the total polygon size.

/// Tests whether positions and straight legs fall on, or cross, land.
struct LandDetector: Sendable {

	/// The coastline this detector tests against.
	let data: CoastalData
	private let grid: EdgeGrid

	/// Creates a detector over a loaded coastline, building its spatial index.
	init(data: CoastalData) {
		self.data = data
		grid = EdgeGrid(polygons: data.polygons, coastlines: data.coastlines)
	}

	// MARK: API

	/// Whether `point` falls on land.
	func isLand(_ point: Coordinate) -> Bool {
		grid.isLand(point)
	}

	/// Whether the straight leg `from` → `to` crosses land.
	///
	/// The endpoints are tested for containment, then the leg is intersection-tested
	/// against every nearby coastline edge via the grid index — both the coarse base
	/// rings and any high-precision tile coastlines — and finally re-tested shifted
	/// by a clearance margin so it never grazes the shore.
	func segmentCrossesLand(from: Coordinate, to: Coordinate) -> Bool {
		// Endpoints first — the cheapest decisive test, and the only one that catches
		// a leg lying wholly inland: such a leg crosses no coastline edge at all.
		if grid.isLand(from) || grid.isLand(to) { return true }
		return seaLegCrossesLand(from: from, to: to)
	}

	/// Whether the straight leg `from` → `to` crosses land, both endpoints being
	/// already known to be at sea.
	///
	/// Identical to ``segmentCrossesLand(from:to:)`` but for the endpoint containment
	/// test, which on such a leg can only answer `false`. That test is the expensive
	/// half: ``isLand(_:)`` casts a ray east and walks the whole grid row beyond the
	/// point, where the leg itself touches only the handful of cells it passes
	/// through. The router asks this of every visibility-graph leg — the graph nudges
	/// its nodes offshore and keeps only those at sea, and both endpoints are snapped
	/// there — which is the difference between a route in seconds and one in tens of
	/// seconds.
	func seaLegCrossesLand(from: Coordinate, to: Coordinate) -> Bool {
		// Exact crossing test against nearby coastline edges.
		if grid.segmentIntersectsCoast(from: from, to: to) { return true }

		// Clearance: keep a margin off the coast. The bundled coastline is a
		// *simplified* outline that often sits inland of the real shore, so a leg
		// that merely clears the polygon can still graze the land the chart shows.
		// Test two copies of the leg shifted perpendicular by the clearance; if
		// either crosses the coast, the original runs too close.
		let dLon = to.longitude - from.longitude
		let dLat = to.latitude - from.latitude
		let length = (dLon * dLon + dLat * dLat).squareRoot()
		if length > 0 {
			let offsetLon = -dLat / length * Self.clearanceDegrees
			let offsetLat = dLon / length * Self.clearanceDegrees
			let port = (
				Coordinate(latitude: from.latitude + offsetLat, longitude: from.longitude + offsetLon),
				Coordinate(latitude: to.latitude + offsetLat, longitude: to.longitude + offsetLon)
			)
			let starboard = (
				Coordinate(latitude: from.latitude - offsetLat, longitude: from.longitude - offsetLon),
				Coordinate(latitude: to.latitude - offsetLat, longitude: to.longitude - offsetLon)
			)
			if grid.segmentIntersectsCoast(from: port.0, to: port.1) { return true }
			if grid.segmentIntersectsCoast(from: starboard.0, to: starboard.1) { return true }
		}

		return false
	}

	/// Whether `point` has sea room: it is at sea, and no coastline edge — ring or
	/// tile polyline — passes within `marginDegrees` of it.
	///
	/// ``segmentCrossesLand(from:to:)`` rejects a leg whose clearance-shifted copy
	/// touches the coast, so a point lying closer to the shore than that clearance
	/// has no usable leg at all, whichever way it heads: one of the two shifted
	/// copies always starts inland. Snapping an endpoint therefore asks for sea
	/// room rather than for mere sea.
	func hasSeaRoom(_ point: Coordinate, marginDegrees: Double) -> Bool {
		!grid.isLand(point) && !grid.coastPasses(within: marginDegrees, of: point)
	}

	/// Clearance a leg must keep off the coast, in degrees (≈ 0.5 nm) — a margin
	/// that absorbs the simplified coastline's inland error so routes don't graze
	/// the real shore.
	private static let clearanceDegrees = 0.5 / 60.0
}

// MARK: - Edge grid index

/// A uniform lat/lon grid bucketing every coastline edge by the cells its
/// bounding box overlaps. Immutable and `Sendable`; built once per dataset.
private struct EdgeGrid: Sendable {

	/// A single coastline edge between two consecutive ring vertices.
	struct Edge: Sendable {
		let a: Coordinate
		let b: Coordinate
		/// Which closed ring the edge came from, or `-1` for an edge of an open tile
		/// polyline. Rings enclose land and so decide containment; a polyline encloses
		/// nothing and takes part only in the crossing test.
		let ring: Int
		/// The westernmost grid column the edge is bucketed into. ``isLand(_:)`` meets
		/// the same edge once per column it spans and counts it only in the first of
		/// them, which this makes a comparison rather than a set lookup.
		let minColumn: Int32
	}

	let edges: [Edge]
	let bounds: GeoBoundingBox
	let columns: Int
	let rows: Int
	let cellWidth: Double
	let cellHeight: Double
	/// Sparse cell → edge-index buckets, keyed by `row * columns + column`.
	let buckets: [Int: [Int]]

	/// Target cell edge length in degrees (≈ 6 nautical miles), a balance between
	/// bucket count and edges per cell.
	private static let targetCellDegrees = 0.1

	init(polygons: [LandPolygon], coastlines: [[Coordinate]] = []) {
		// The grid geometry settles which cells an edge belongs to, so the extent of
		// the data has to be measured before any edge is built.
		let bounds = Self.extent(of: polygons, and: coastlines)
		self.bounds = bounds

		let width = max(bounds.maxLongitude - bounds.minLongitude, Self.targetCellDegrees)
		let height = max(bounds.maxLatitude - bounds.minLatitude, Self.targetCellDegrees)
		let columns = max(1, Int((width / Self.targetCellDegrees).rounded(.up)))
		let rows = max(1, Int((height / Self.targetCellDegrees).rounded(.up)))
		self.columns = columns
		self.rows = rows
		cellWidth = width / Double(columns)
		cellHeight = height / Double(rows)

		(edges, buckets) = Self.index(
			polygons: polygons, coastlines: coastlines, bounds: bounds,
			columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
	}

	/// The union of every vertex in the dataset, or a degenerate box when there are
	/// none. Walking the vertices is cheaper than gathering them: the alternative is
	/// a second copy of a quarter of a million coordinates, live at the moment the
	/// edges are being built.
	private static func extent(of polygons: [LandPolygon], and coastlines: [[Coordinate]]) -> GeoBoundingBox {
		var minLatitude = Double.infinity
		var maxLatitude = -Double.infinity
		var minLongitude = Double.infinity
		var maxLongitude = -Double.infinity
		func include(_ point: Coordinate) {
			minLatitude = Swift.min(minLatitude, point.latitude)
			maxLatitude = Swift.max(maxLatitude, point.latitude)
			minLongitude = Swift.min(minLongitude, point.longitude)
			maxLongitude = Swift.max(maxLongitude, point.longitude)
		}
		for polygon in polygons {
			for point in polygon.points { include(point) }
		}
		for line in coastlines {
			for point in line { include(point) }
		}
		guard minLatitude <= maxLatitude else {
			return GeoBoundingBox(minLatitude: 0, maxLatitude: 0, minLongitude: 0, maxLongitude: 0)
		}
		return GeoBoundingBox(
			minLatitude: minLatitude, maxLatitude: maxLatitude,
			minLongitude: minLongitude, maxLongitude: maxLongitude)
	}

	/// Flattens every ring into its closing edges (the closed-polygon geometry),
	/// then the open coastline polylines (consecutive vertices, not closed), and
	/// buckets each edge into every cell its bounding box overlaps as it is made.
	private static func index(
		polygons: [LandPolygon],
		coastlines: [[Coordinate]],
		bounds: GeoBoundingBox,
		columns: Int,
		rows: Int,
		cellWidth: Double,
		cellHeight: Double
	) -> (edges: [Edge], buckets: [Int: [Int]]) {
		var edges: [Edge] = []
		edges.reserveCapacity(
			polygons.reduce(0) { $0 + $1.points.count }
				+ coastlines.reduce(0) { $0 + max($1.count - 1, 0) })
		var buckets: [Int: [Int]] = [:]

		func add(_ a: Coordinate, _ b: Coordinate, ring: Int) {
			let minColumn = clampedColumn(
				for: min(a.longitude, b.longitude), bounds: bounds, cellWidth: cellWidth, columns: columns)
			let maxColumn = clampedColumn(
				for: max(a.longitude, b.longitude), bounds: bounds, cellWidth: cellWidth, columns: columns)
			let minRow = clampedRow(
				for: min(a.latitude, b.latitude), bounds: bounds, cellHeight: cellHeight, rows: rows)
			let maxRow = clampedRow(
				for: max(a.latitude, b.latitude), bounds: bounds, cellHeight: cellHeight, rows: rows)
			let index = edges.count
			edges.append(Edge(a: a, b: b, ring: ring, minColumn: Int32(minColumn)))
			for row in minRow...maxRow {
				for column in minColumn...maxColumn {
					buckets[row * columns + column, default: []].append(index)
				}
			}
		}

		for (ring, polygon) in polygons.enumerated() {
			let points = polygon.points
			var previous = points.count - 1
			for index in points.indices {
				add(points[previous], points[index], ring: ring)
				previous = index
			}
		}
		for line in coastlines {
			for index in line.indices.dropFirst() {
				add(line[index - 1], line[index], ring: -1)
			}
		}
		return (edges, buckets)
	}

	// MARK: Queries

	/// Even-odd point-in-polygon test by casting a ray due east from `point` and
	/// counting the coastline edges it crosses, scanning only the point's grid
	/// row. A point outside the grid bounds is open water.
	///
	/// The crossings are counted *per ring* and the point is land if any one ring
	/// encloses it. Pooling them into a single even-odd count would be wrong here:
	/// the dataset is a union of independent land features, of which the loader keeps
	/// each outer ring and drops the holes, so two rings drawn over the same ground
	/// must union rather than cancel — and counting the winding instead would not
	/// help, the duplicates being wound opposite ways.
	///
	/// They are not hypothetical. The coastline as first published drew Corsica, Elba
	/// and a dozen smaller islands twice over, a high-detail OSM outline merged on top
	/// of the coarse base, and a pooled count hollowed every one of them out:
	/// everything inland read as open water, an endpoint ashore was snapped into the
	/// middle of the island, and the route came back as `noRouteFound`. The published
	/// data has since been de-duplicated, but a device that downloaded the earlier one
	/// still carries it, and nothing in the format stops one outline being merged over
	/// another again.
	func isLand(_ point: Coordinate) -> Bool {
		guard bounds.contains(point) else { return false }
		let row = clampedRow(point.latitude)
		let startColumn = clampedColumn(point.longitude)
		var crossings: [Int: Int] = [:]
		for column in startColumn..<columns {
			guard let bucket = buckets[row * columns + column] else { continue }
			for index in bucket {
				let edge = edges[index]
				// An edge is bucketed into every cell it overlaps, so the scan meets it
				// once per column it spans and must count it only once: in the first of
				// those columns the scan reaches. ``Edge/minColumn`` settles that by
				// comparison rather than by remembering every edge seen — this ray cast
				// is the hottest loop in the library, and hashing dominated it.
				guard Swift.max(Int(edge.minColumn), startColumn) == column else { continue }
				// Only closed rings define containment; the open tile polylines are
				// skipped (they would corrupt the crossing count).
				guard edge.ring >= 0 else { continue }
				let ya = edge.a.latitude
				let yb = edge.b.latitude
				guard (ya > point.latitude) != (yb > point.latitude) else { continue }
				let crossingLongitude =
					(edge.b.longitude - edge.a.longitude) * (point.latitude - ya) / (yb - ya) + edge.a.longitude
				if crossingLongitude >= point.longitude { crossings[edge.ring, default: 0] += 1 }
			}
		}
		return crossings.values.contains { $0 % 2 == 1 }
	}

	/// Whether the leg `from` → `to` intersects any coastline edge, walking only
	/// the cells the leg passes through (Amanatides–Woo grid traversal).
	///
	/// An edge spanning several of those cells is tested once per cell rather than
	/// remembered: the test is a handful of arithmetic, where hashing it into a set
	/// of seen edges cost more than the repeats ever do.
	func segmentIntersectsCoast(from: Coordinate, to: Coordinate) -> Bool {
		var hit = false
		traverseCells(from: from, to: to) { key in
			guard let bucket = buckets[key] else { return true }
			for index in bucket {
				let edge = edges[index]
				if LandDetector.segmentsIntersect(from, to, edge.a, edge.b) {
					hit = true
					return false  // stop traversal
				}
			}
			return true
		}
		return hit
	}

	/// Whether any coastline edge passes within `margin` degrees of `point`,
	/// scanning only the cells the margin box overlaps. Unlike ``isLand(_:)`` this
	/// counts the open tile polylines too: they are coast a hull can hit.
	func coastPasses(within margin: Double, of point: Coordinate) -> Bool {
		let minColumn = clampedColumn(point.longitude - margin)
		let maxColumn = clampedColumn(point.longitude + margin)
		let minRow = clampedRow(point.latitude - margin)
		let maxRow = clampedRow(point.latitude + margin)
		for row in minRow...maxRow {
			for column in minColumn...maxColumn {
				guard let bucket = buckets[row * columns + column] else { continue }
				for index in bucket {
					let edge = edges[index]
					if LandDetector.distanceToSegmentDegrees(point, edge.a, edge.b) <= margin { return true }
				}
			}
		}
		return false
	}

	// MARK: Grid traversal

	/// Visits each grid cell the leg `from` → `to` passes through, calling `body`
	/// with the cell key; `body` returns `false` to stop early. The leg is first
	/// clamped to the grid bounds so traversal stays in range.
	private func traverseCells(from: Coordinate, to: Coordinate, _ body: (Int) -> Bool) {
		var column = clampedColumn(from.longitude)
		var row = clampedRow(from.latitude)
		let endColumn = clampedColumn(to.longitude)
		let endRow = clampedRow(to.latitude)

		let stepColumn = to.longitude > from.longitude ? 1 : (to.longitude < from.longitude ? -1 : 0)
		let stepRow = to.latitude > from.latitude ? 1 : (to.latitude < from.latitude ? -1 : 0)

		let deltaLon = to.longitude - from.longitude
		let deltaLat = to.latitude - from.latitude

		// Parametric distances (t in 0...1) to the next cell boundary and between
		// successive boundaries, per axis.
		var tMaxX = Double.infinity
		var tDeltaX = Double.infinity
		if stepColumn != 0 {
			let nextBoundary =
				bounds.minLongitude + Double(column + (stepColumn > 0 ? 1 : 0)) * cellWidth
			tMaxX = (nextBoundary - from.longitude) / deltaLon
			tDeltaX = cellWidth / abs(deltaLon)
		}
		var tMaxY = Double.infinity
		var tDeltaY = Double.infinity
		if stepRow != 0 {
			let nextBoundary =
				bounds.minLatitude + Double(row + (stepRow > 0 ? 1 : 0)) * cellHeight
			tMaxY = (nextBoundary - from.latitude) / deltaLat
			tDeltaY = cellHeight / abs(deltaLat)
		}

		// Guard against a pathological cell count.
		let maxCells = columns + rows + 2
		var visited = 0
		while visited <= maxCells {
			visited += 1
			if !body(row * columns + column) { return }
			if column == endColumn && row == endRow { return }
			if tMaxX < tMaxY {
				if column == endColumn { return }
				tMaxX += tDeltaX
				column += stepColumn
			} else {
				if row == endRow { return }
				tMaxY += tDeltaY
				row += stepRow
			}
			if column < 0 || column >= columns || row < 0 || row >= rows { return }
		}
	}

	// MARK: Cell indexing

	private func clampedColumn(_ longitude: Double) -> Int {
		Self.clampedColumn(for: longitude, bounds: bounds, cellWidth: cellWidth, columns: columns)
	}

	private func clampedRow(_ latitude: Double) -> Int {
		Self.clampedRow(for: latitude, bounds: bounds, cellHeight: cellHeight, rows: rows)
	}

	private static func clampedColumn(for longitude: Double, bounds: GeoBoundingBox, cellWidth: Double, columns: Int)
		-> Int
	{
		let raw = Int((longitude - bounds.minLongitude) / cellWidth)
		return Swift.min(Swift.max(raw, 0), columns - 1)
	}

	private static func clampedRow(for latitude: Double, bounds: GeoBoundingBox, cellHeight: Double, rows: Int) -> Int {
		let raw = Int((latitude - bounds.minLatitude) / cellHeight)
		return Swift.min(Swift.max(raw, 0), rows - 1)
	}
}

// MARK: - Geometry primitives

extension LandDetector {

	/// Whether segments `p1p2` and `p3p4` intersect, using the standard
	/// orientation test (treating collinear-overlap as an intersection too).
	static func segmentsIntersect(_ p1: Coordinate, _ p2: Coordinate, _ p3: Coordinate, _ p4: Coordinate) -> Bool {
		let d1 = orientation(p3, p4, p1)
		let d2 = orientation(p3, p4, p2)
		let d3 = orientation(p1, p2, p3)
		let d4 = orientation(p1, p2, p4)

		if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
			&& ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
		{
			return true
		}
		if d1 == 0, onSegment(p3, p4, p1) { return true }
		if d2 == 0, onSegment(p3, p4, p2) { return true }
		if d3 == 0, onSegment(p1, p2, p3) { return true }
		if d4 == 0, onSegment(p1, p2, p4) { return true }
		return false
	}

	/// Distance, in degrees, from `point` to the segment `a`→`b`, taking longitude
	/// and latitude as plain axes — the same flat measure the coast clearance and the
	/// router's search margins are expressed in.
	static func distanceToSegmentDegrees(_ point: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Double {
		let dx = b.longitude - a.longitude
		let dy = b.latitude - a.latitude
		let px = point.longitude - a.longitude
		let py = point.latitude - a.latitude
		let lengthSquared = dx * dx + dy * dy
		guard lengthSquared > 0 else { return (px * px + py * py).squareRoot() }
		let t = Swift.max(0, Swift.min(1, (px * dx + py * dy) / lengthSquared))
		let cx = px - t * dx
		let cy = py - t * dy
		return (cx * cx + cy * cy).squareRoot()
	}

	/// The signed area (× 2) of triangle `abc`: positive for a counter-clockwise
	/// turn, negative for clockwise, zero when collinear.
	private static func orientation(_ a: Coordinate, _ b: Coordinate, _ c: Coordinate) -> Double {
		(b.longitude - a.longitude) * (c.latitude - a.latitude)
			- (b.latitude - a.latitude) * (c.longitude - a.longitude)
	}

	/// Whether `point` lies within the bounding box of segment `ab` (used only
	/// when the three are already known to be collinear).
	private static func onSegment(_ a: Coordinate, _ b: Coordinate, _ point: Coordinate) -> Bool {
		Swift.min(a.longitude, b.longitude) <= point.longitude
			&& point.longitude <= Swift.max(a.longitude, b.longitude)
			&& Swift.min(a.latitude, b.latitude) <= point.latitude
			&& point.latitude <= Swift.max(a.latitude, b.latitude)
	}
}
