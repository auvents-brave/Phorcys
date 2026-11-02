import Foundation
public import Stheno

// Parses the simplified Natural Earth land polygons (public domain,
// `ne_10m_land`, cropped and decimated with mapshaper) into ``CoastalData``.
// Two datasets are used: a detailed Mediterranean + Atlantic-approaches crop and
// a coarse worldwide fallback. They no longer travel in the app bundle —
// ``CoastalDataStore`` downloads them and hands this loader the directory.

/// Loads the downloaded coastline GeoJSON into ``CoastalData``.
enum CoastalDataLoader {

	/// The single base coastline resource: the worldwide `ne_10m_land` coast
	/// with OSM small-island detail merged in for the regions that need it.
	static let resourceName = "CoastalLand"

	/// Filename prefix of a high-precision coastline tile (`coast_E000_N40.geojson`).
	/// Tiles carry `LineString` features and are loaded alongside the base.
	static let tilePrefix = "coast_"

	/// A failure loading or decoding a dataset.
	enum LoadError: Error, CustomStringConvertible {
		case resourceMissing(String)
		case decodeFailed(String, underlying: any Error)

		var description: String {
			switch self {
			case .resourceMissing(let name):
				"The coastline data ‘\(name)’ is missing."
			case .decodeFailed(let name, let underlying):
				"The coastline data ‘\(name)’ could not be read: \(underlying)"
			}
		}
	}

	/// Loads and parses the coastline held in `directory`.
	///
	/// - Parameter directory: The directory the datasets were downloaded into,
	///   as ``CoastalDataStore/ensureReady(progress:)`` returns it.
	/// - Returns: The parsed land polygons.
	/// - Throws: ``LoadError`` when a dataset is missing or malformed.
	static func load(from directory: URL) throws -> CoastalData {
		let baseURL = directory.appending(path: "\(resourceName).geojson")
		guard FileManager.default.fileExists(atPath: baseURL.path(percentEncoded: false)) else {
			throw LoadError.resourceMissing(resourceName)
		}
		let polygons = try decode(at: baseURL, named: resourceName)
			.features.flatMap(\.geometry.rings).compactMap(LandPolygon.init(points:))

		// High-precision coastline tiles sitting alongside the base, if any. A
		// tile that fails to decode is skipped rather than failing the whole load —
		// the coarse base still routes everywhere.
		let tileURLs = ((try? FileManager.default.contentsOfDirectory(
			at: directory, includingPropertiesForKeys: nil)) ?? [])
			.filter { $0.lastPathComponent.hasPrefix(tilePrefix) && $0.pathExtension == "geojson" }
		let coastlines = tileURLs.flatMap { url in
			((try? decode(at: url, named: url.lastPathComponent))?.features.flatMap(\.geometry.lines)) ?? []
		}

		return CoastalData(polygons: polygons, coastlines: coastlines)
	}

	/// Decodes a GeoJSON feature collection from `url`, mapping failures to
	/// ``LoadError``.
	private static func decode(at url: URL, named name: String) throws -> GeoJSONFeatureCollection {
		do {
			return try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: Data(contentsOf: url))
		} catch {
			throw LoadError.decodeFailed(name, underlying: error)
		}
	}
}

// MARK: - GeoJSON decoding

// A typed, minimal GeoJSON reader: we only need the outer rings of Polygon and
// MultiPolygon geometries, so the model stays small and avoids `Any`.

private struct GeoJSONFeatureCollection: Decodable {
	let features: [GeoJSONFeature]
}

private struct GeoJSONFeature: Decodable {
	let geometry: GeoJSONGeometry
}

/// A decoded geometry reduced to its outer rings (holes are inland water; for
/// marine routing a point inside one is treated as land, which is conservative
/// and never affects an at-sea route).
private struct GeoJSONGeometry: Decodable {
	/// One ring per polygon — each polygon's first (outer) ring.
	let rings: [[Coordinate]]
	/// Open coastline polylines (from `LineString`/`MultiLineString` tile features).
	let lines: [[Coordinate]]

	private enum CodingKeys: String, CodingKey {
		case type
		case coordinates
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)
		switch type {
		case "Polygon":
			// coordinates: [ring][vertex][lon, lat] — take the outer ring.
			let polygon = try container.decode([[[Double]]].self, forKey: .coordinates)
			rings = polygon.first.map { [Self.ring(from: $0)] } ?? []
			lines = []
		case "MultiPolygon":
			// coordinates: [polygon][ring][vertex][lon, lat] — outer ring of each.
			let multi = try container.decode([[[[Double]]]].self, forKey: .coordinates)
			rings = multi.compactMap { polygon in polygon.first.map(Self.ring(from:)) }
			lines = []
		case "LineString":
			// coordinates: [vertex][lon, lat].
			let line = try container.decode([[Double]].self, forKey: .coordinates)
			rings = []
			lines = [Self.ring(from: line)]
		case "MultiLineString":
			// coordinates: [line][vertex][lon, lat].
			let multi = try container.decode([[[Double]]].self, forKey: .coordinates)
			rings = []
			lines = multi.map(Self.ring(from:))
		default:
			rings = []
			lines = []
		}
	}

	/// Converts a GeoJSON ring (`[[lon, lat]]`) into ``Coordinate`` values.
	private static func ring(from vertices: [[Double]]) -> [Coordinate] {
		vertices.compactMap { pair in
			pair.count >= 2 ? Coordinate(latitude: pair[1], longitude: pair[0]) : nil
		}
	}
}
