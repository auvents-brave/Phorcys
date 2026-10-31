# Phorcys

What Thoôsa and its companion both need, and nothing else does.

The sibling libraries each have a clear remit — [Sthenô](https://github.com/auvents-brave/Stheno) is
generic Swift, [Euryale](https://github.com/auvents-brave/Euryale) generic SwiftUI, and
[BoatTools](https://github.com/auvents-brave/BoatTools) the boat's own business: NMEA, AIS, Signal K,
GMDSS. Phorcys holds what is specific to the apps themselves and would otherwise
be written twice, once in Swift and once in C#, to drift apart quietly.

Everything here is arithmetic with no platform behind it, so it builds wherever
Swift does and can be exercised without a boat, a printer or the network.

- **`CollisionGeometry`** — the closest point of approach between two vessels: how
  far apart they will be at it, and how many minutes from now. Worked on the local
  tangent plane, which is accurate well past any range at which an AIS target matters.
  With the rules that decide when an approach is worth raising: the half-hour horizon,
  the half-knot floor below which a vessel is at anchor rather than under way, and the
  clearance factor that stops a target sitting on the threshold from flickering.
- **`OfflineTiles`** — which tiles a passage needs, as a corridor along the route rather
  than the box it sits in. The corridor holds under half the tiles for the same cover,
  which is what makes the close zoom levels affordable, and it bounds the request by
  construction: there is no way to ask for a whole sea.
- **`ReceiptLayout`** — a logbook laid out for a thermal roll and encoded as ESC/POS:
  columns from the paper's width, where a line breaks, and Windows-1252 written out
  rather than taken from Foundation, whose encodings differ away from Apple's platforms.

## The bridge

`Bridge/` builds **libPhorcysBridge**, a dynamic library exposing the above through a
plain C ABI (`phorcys_bridge_*`) for non-Swift hosts — the companion app calls it by
P/Invoke. Build it with `swift build -c release` from that directory. Buffers handed
back are the caller's to release, with `phorcys_bridge_bytes_free`.

## Tests

`swift test`. They pin what can be checked without hardware, which for a roll printer
nobody has to hand is the whole of it.
