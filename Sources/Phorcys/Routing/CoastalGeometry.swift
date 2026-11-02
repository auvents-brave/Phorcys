import Foundation
public import Stheno

// The lightweight value types underpinning the offline coastal router. They are
// all `Sendable` so the (large) land geometry and the computed routes can move
// freely between the loader, the routing actor and the main actor.

// The router works in Sthenô's ``Coordinate`` throughout — the app's own point
// type bridges to it at the edges — and adds here the great-circle helpers the
// search needs.

extension Coordinate {
	/// One nautical mile expressed in kilometres.
	public static let kilometresPerNauticalMile = 1.852
	/// Mean Earth radius in nautical miles (matches Stheno's 6371 km Haversine
	/// model, converted; Stheno keeps its own constant internal).
	static let earthRadiusNauticalMiles = 6371.0 / 1.852

	/// The great-circle distance to another point, in nautical miles, via Stheno's
	/// Haversine ``Geo/distance(from:to:)``.
	func distanceNauticalMiles(to other: Coordinate) -> Double {
		Geo.distance(from: self, to: other) / Self.kilometresPerNauticalMile
	}

	/// The great-circle distance to another point, in kilometres.
	func distanceKilometres(to other: Coordinate) -> Double {
		Geo.distance(from: self, to: other)
	}

	/// Linear interpolation in lat/lon space between `self` (t = 0) and `other`
	/// (t = 1). Accurate enough for the short legs the router samples; the engine
	/// works at coastal scales well away from the poles and the antimeridian.
	func interpolated(towards other: Coordinate, fraction t: Double) -> Coordinate {
		Coordinate(
			latitude: latitude + (other.latitude - latitude) * t,
			longitude: longitude + (other.longitude - longitude) * t
		)
	}

	/// The destination reached by travelling `distanceNauticalMiles` along the
	/// initial great-circle `bearing` (degrees from true north). Used to spiral a
	/// land-locked endpoint out to open water.
	func destination(bearing bearingDegrees: Double, distanceNauticalMiles: Double) -> Coordinate {
		let angularDistance = distanceNauticalMiles / Self.earthRadiusNauticalMiles
		let bearing = bearingDegrees * .pi / 180
		let lat1 = latitudeRadians
		let lon1 = longitudeRadians

		let lat2 = asin(
			sin(lat1) * cos(angularDistance)
				+ cos(lat1) * sin(angularDistance) * cos(bearing)
		)
		let lon2 =
			lon1
			+ atan2(
				sin(bearing) * sin(angularDistance) * cos(lat1),
				cos(angularDistance) - sin(lat1) * sin(lat2)
			)
		return Coordinate(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
	}

	private var latitudeRadians: Double { latitude * .pi / 180 }
	private var longitudeRadians: Double { longitude * .pi / 180 }
}

// MARK: - Bounding box

/// An axis-aligned latitude/longitude bounding box, used for the fast reject
/// tests that keep point-in-polygon and segment-intersection cheap.
struct GeoBoundingBox: Sendable, Equatable {
	var minLatitude: Double
	var maxLatitude: Double
	var minLongitude: Double
	var maxLongitude: Double

	/// The smallest box enclosing `points`, or `nil` for an empty input.
	init?(points: [Coordinate]) {
		guard let first = points.first else { return nil }
		var minLat = first.latitude
		var maxLat = first.latitude
		var minLon = first.longitude
		var maxLon = first.longitude
		for point in points.dropFirst() {
			minLat = Swift.min(minLat, point.latitude)
			maxLat = Swift.max(maxLat, point.latitude)
			minLon = Swift.min(minLon, point.longitude)
			maxLon = Swift.max(maxLon, point.longitude)
		}
		minLatitude = minLat
		maxLatitude = maxLat
		minLongitude = minLon
		maxLongitude = maxLon
	}

	init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
		self.minLatitude = minLatitude
		self.maxLatitude = maxLatitude
		self.minLongitude = minLongitude
		self.maxLongitude = maxLongitude
	}

	/// Whether `point` lies inside (or on the edge of) the box.
	func contains(_ point: Coordinate) -> Bool {
		point.latitude >= minLatitude && point.latitude <= maxLatitude
			&& point.longitude >= minLongitude && point.longitude <= maxLongitude
	}

	/// Whether this box and `other` overlap (a fast reject for edge tests).
	func intersects(_ other: GeoBoundingBox) -> Bool {
		minLatitude <= other.maxLatitude && maxLatitude >= other.minLatitude
			&& minLongitude <= other.maxLongitude && maxLongitude >= other.minLongitude
	}

	/// A copy grown outward by `fraction` of its own width/height on every side
	/// (e.g. `0.2` for the 20 % margin the visibility graph uses).
	func expanded(by fraction: Double) -> GeoBoundingBox {
		let latMargin = (maxLatitude - minLatitude) * fraction
		let lonMargin = (maxLongitude - minLongitude) * fraction
		return GeoBoundingBox(
			minLatitude: minLatitude - latMargin,
			maxLatitude: maxLatitude + latMargin,
			minLongitude: minLongitude - lonMargin,
			maxLongitude: maxLongitude + lonMargin
		)
	}

	/// A copy grown outward by the same number of `degrees` on every side. Unlike
	/// ``expanded(by:)`` this adds an equal margin to both axes, so a near-flat
	/// route (tiny extent in one axis) still gains room for a detour around a
	/// large obstacle.
	func expandedByDegrees(_ degrees: Double) -> GeoBoundingBox {
		GeoBoundingBox(
			minLatitude: minLatitude - degrees,
			maxLatitude: maxLatitude + degrees,
			minLongitude: minLongitude - degrees,
			maxLongitude: maxLongitude + degrees
		)
	}

	/// The diagonal extent of the box, in degrees.
	var diagonalDegrees: Double {
		let dLat = maxLatitude - minLatitude
		let dLon = maxLongitude - minLongitude
		return (dLat * dLat + dLon * dLon).squareRoot()
	}
}

// MARK: - Land polygons

/// A single closed land polygon (one Natural Earth ring), with its precomputed
/// bounding box so callers can reject the vast majority of polygons before the
/// per-vertex maths.
struct LandPolygon: Sendable {
	/// The ring's vertices, in order. Not explicitly closed (the last/first edge
	/// is implied).
	let points: [Coordinate]
	/// The ring's bounding box.
	let boundingBox: GeoBoundingBox

	/// Creates a polygon from a ring, computing its bounding box. Returns `nil`
	/// for a degenerate ring of fewer than three points.
	init?(points: [Coordinate]) {
		guard points.count >= 3, let box = GeoBoundingBox(points: points) else { return nil }
		self.points = points
		boundingBox = box
	}
}

/// The loaded coastline: every land ring for one dataset, ready for the
/// ``LandDetector``. Immutable and `Sendable`.
struct CoastalData: Sendable {
	/// Every land polygon (outer rings) of the dataset.
	let polygons: [LandPolygon]
	/// Open, high-precision coastline polylines from downloadable OSM tiles. Used
	/// only by the leg-crosses-coast test — never for point-in-land containment,
	/// since they are open lines, not closed rings.
	let coastlines: [[Coordinate]]

	init(polygons: [LandPolygon], coastlines: [[Coordinate]] = []) {
		self.polygons = polygons
		self.coastlines = coastlines
	}

	/// The polygons as the array-of-rings shape the feature specification calls
	/// for. Computed on demand (the engine itself works on ``polygons``).
	var polygonsAsCoordinates: [[Coordinate]] {
		polygons.map(\.points)
	}
}
