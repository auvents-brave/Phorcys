#if canImport(CoreLocation)
	public import CoreLocation
	public import Stheno

	// Apple's hosts carry their route as CoreLocation coordinates, and
	// converting at each call site would put the same two lines in several
	// places. The guard keeps this out of the way where there is no
	// CoreLocation — Windows and Linux, where the companion's bridge builds.

	extension OfflineTiles {

		/// Every tile within `widthNM / 2` of the route, at each zoom in `zooms`.
		///
		/// - Parameters:
		///   - route: The passage, in order. Fewer than two points yields nothing.
		///   - widthNM: The corridor's full width, in nautical miles.
		///   - zooms: The zoom levels to cover.
		/// - Returns: The tiles to hold, with no duplicates.
		public static func tiles(
			along route: [CLLocationCoordinate2D], widthNM: Double, zooms: ClosedRange<Int>
		) -> Set<TileIndex> {
			tiles(
				along: route.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) },
				widthNM: widthNM, zooms: zooms)
		}

		/// How many tiles that corridor holds — the figure the download sheet
		/// shows before anything is fetched.
		///
		/// - Parameters:
		///   - route: The passage, in order.
		///   - widthNM: The corridor's full width, in nautical miles.
		///   - zooms: The zoom levels to cover.
		/// - Returns: The number of distinct tiles.
		public static func tileCount(
			along route: [CLLocationCoordinate2D], widthNM: Double, zooms: ClosedRange<Int>
		) -> Int {
			tiles(along: route, widthNM: widthNM, zooms: zooms).count
		}
	}
#endif
