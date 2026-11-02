import Foundation
import Phorcys
import Stheno

/// Plans a land-avoiding coastal route.
///
/// The search lives in `Phorcys.CoastalRouter`; this carries it across the C
/// boundary so the companion app plans the same routes as the Apple one rather
/// than growing a second engine. The host is responsible for putting the
/// coastline GeoJSON on disk — each platform downloads it with its own HTTP
/// stack — and passes the directory in.

/// A plan, as it crosses the boundary.
private struct RouteResult: Encodable {
	/// The waypoints as `[latitude, longitude]` pairs, start and end included.
	var waypoints: [[Double]]?
	/// Why no route could be planned, in plain English.
	var error: String?
}

/// Encodes `result` into a caller-owned buffer.
private func encoded(_ result: RouteResult, _ outLength: UnsafeMutablePointer<Int32>?)
	-> UnsafeMutablePointer<UInt8>?
{
	let bytes = (try? JSONEncoder().encode(result)).map(Array.init) ?? Array(#"{"error":"encoding"}"#.utf8)
	let out = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, bytes.count))
	out.update(from: bytes, count: bytes.count)
	outLength?.pointee = Int32(bytes.count)
	return out
}

/// Plans a route that stays at sea.
///
/// - Parameters:
///   - dataDirectory: The directory holding `CoastalLand.geojson` and any
///     `coast_*.geojson` tiles, UTF-8.
///   - startLatitude: Where the passage begins, degrees.
///   - startLongitude: Where the passage begins, degrees.
///   - endLatitude: Where it ends, degrees.
///   - endLongitude: Where it ends, degrees.
///   - timeoutSeconds: The search's time budget; 0 or less means 30 seconds.
///   - outLength: Filled with the buffer's length in bytes.
/// - Returns: UTF-8 JSON — `{"waypoints":[[lat,lon],…]}` on success, or
///   `{"error":"…"}` — to release with `phorcys_bridge_bytes_free`. This call
///   blocks until the search finishes, so a host must not make it on a thread
///   that draws.
@_cdecl("phorcys_bridge_route_plan")
public func phorcys_bridge_route_plan(
	_ dataDirectory: UnsafePointer<CChar>?,
	_ startLatitude: Double,
	_ startLongitude: Double,
	_ endLatitude: Double,
	_ endLongitude: Double,
	_ timeoutSeconds: Int32,
	_ outLength: UnsafeMutablePointer<Int32>?
) -> UnsafeMutablePointer<UInt8>? {
	guard let dataDirectory else {
		return encoded(RouteResult(error: "No coastline directory was given."), outLength)
	}
	let directory = URL(fileURLWithPath: String(cString: dataDirectory), isDirectory: true)
	let budget = timeoutSeconds > 0 ? Duration.seconds(Int(timeoutSeconds)) : .seconds(30)
	let router = CoastalRouter(timeout: budget, dataDirectory: { directory })

	// The router is an actor and the C boundary is synchronous, so the call is
	// bridged with a semaphore. Safe because the caller is one of the host's own
	// threads, never Swift's cooperative pool — which is also why the
	// documentation insists this is not called from a thread that draws.
	let semaphore = DispatchSemaphore(value: 0)
	nonisolated(unsafe) var outcome = RouteResult(error: "The search did not run.")
	Task {
		do {
			let route = try await router.calculateRoute(
				from: Coordinate(latitude: startLatitude, longitude: startLongitude),
				to: Coordinate(latitude: endLatitude, longitude: endLongitude))
			outcome = RouteResult(waypoints: route.map { [$0.latitude, $0.longitude] })
		} catch let error as CoastalRouter.RoutingError {
			outcome = RouteResult(error: error.summary)
		} catch {
			outcome = RouteResult(error: "\(error)")
		}
		semaphore.signal()
	}
	semaphore.wait()
	return encoded(outcome, outLength)
}
