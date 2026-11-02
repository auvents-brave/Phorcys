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
		// Endpoints first — the cheapest decisive test.
		if grid.isLand(from) || grid.isLand(to) { return true }

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
	}

	let edges: [Edge]
	/// Number of leading entries in `edges` that belong to closed rings. Ring
	/// edges drive both containment and crossing; the open coastline edges that
	/// follow (`index >= ringEdgeCount`) drive only the crossing test.
	let ringEdgeCount: Int
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
		// Flatten every ring into its closing edges (the closed-polygon geometry).
		var edges: [Edge] = []
		for polygon in polygons {
			let points = polygon.points
			var previous = points.count - 1
			for index in points.indices {
				edges.append(Edge(a: points[previous], b: points[index]))
				previous = index
			}
		}
		ringEdgeCount = edges.count

		// Append the open coastline polylines (consecutive vertices, not closed).
		for line in coastlines {
			for index in line.indices.dropFirst() {
				edges.append(Edge(a: line[index - 1], b: line[index]))
			}
		}
		self.edges = edges

		// Overall bounds (union of every edge endpoint), with a hair of padding.
		let allPoints = edges.flatMap { [$0.a, $0.b] }
		let bounds =
			GeoBoundingBox(points: allPoints)
			?? GeoBoundingBox(minLatitude: 0, maxLatitude: 0, minLongitude: 0, maxLongitude: 0)
		self.bounds = bounds

		let width = max(bounds.maxLongitude - bounds.minLongitude, Self.targetCellDegrees)
		let height = max(bounds.maxLatitude - bounds.minLatitude, Self.targetCellDegrees)
		let columns = max(1, Int((width / Self.targetCellDegrees).rounded(.up)))
		let rows = max(1, Int((height / Self.targetCellDegrees).rounded(.up)))
		self.columns = columns
		self.rows = rows
		cellWidth = width / Double(columns)
		cellHeight = height / Double(rows)

		// Insert each edge into every cell its bounding box overlaps.
		var buckets: [Int: [Int]] = [:]
		for (index, edge) in edges.enumerated() {
			let minCol = Self.clampedColumn(
				for: min(edge.a.longitude, edge.b.longitude), bounds: bounds, cellWidth: width / Double(columns),
				columns: columns)
			let maxCol = Self.clampedColumn(
				for: max(edge.a.longitude, edge.b.longitude), bounds: bounds, cellWidth: width / Double(columns),
				columns: columns)
			let minRow = Self.clampedRow(
				for: min(edge.a.latitude, edge.b.latitude), bounds: bounds, cellHeight: height / Double(rows),
				rows: rows)
			let maxRow = Self.clampedRow(
				for: max(edge.a.latitude, edge.b.latitude), bounds: bounds, cellHeight: height / Double(rows),
				rows: rows)
			for row in minRow...maxRow {
				for column in minCol...maxCol {
					buckets[row * columns + column, default: []].append(index)
				}
			}
		}
		self.buckets = buckets
	}

	// MARK: Queries

	/// Even-odd point-in-polygon test by casting a ray due east from `point` and
	/// counting the coastline edges it crosses, scanning only the point's grid
	/// row. A point outside the grid bounds is open water.
	func isLand(_ point: Coordinate) -> Bool {
		guard bounds.contains(point) else { return false }
		let row = clampedRow(point.latitude)
		let startColumn = clampedColumn(point.longitude)
		var crossings = 0
		var seen = Set<Int>()
		for column in startColumn..<columns {
			guard let bucket = buckets[row * columns + column] else { continue }
			// Only closed-ring edges define containment; open coastline edges are
			// skipped (they would corrupt the even-odd crossing count).
			for index in bucket where index < ringEdgeCount && !seen.contains(index) {
				seen.insert(index)
				let edge = edges[index]
				let ya = edge.a.latitude
				let yb = edge.b.latitude
				guard (ya > point.latitude) != (yb > point.latitude) else { continue }
				let crossingLongitude =
					(edge.b.longitude - edge.a.longitude) * (point.latitude - ya) / (yb - ya) + edge.a.longitude
				if crossingLongitude >= point.longitude { crossings += 1 }
			}
		}
		return crossings % 2 == 1
	}

	/// Whether the leg `from` → `to` intersects any coastline edge, walking only
	/// the cells the leg passes through (Amanatides–Woo grid traversal).
	func segmentIntersectsCoast(from: Coordinate, to: Coordinate) -> Bool {
		var seen = Set<Int>()
		var hit = false
		traverseCells(from: from, to: to) { key in
			guard let bucket = buckets[key] else { return true }
			for index in bucket where !seen.contains(index) {
				seen.insert(index)
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
