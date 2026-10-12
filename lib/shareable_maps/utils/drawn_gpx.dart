// GPX for elements drawn by hand into a cloud folder layer.
//
// A cloud tracks/waypoints layer is not stored on the map — it is rebuilt
// from the GPX files in the linked Storage folder, and the
// `compileGpxOnUpload` Cloud Function recompiles that folder whenever a GPX
// lands in it. So the only way a drawn marker or line can *belong* to such a
// layer, and still be there after a reload, is as a GPX file in that folder.
//
// Two deliberate choices:
//
//  * No `<time>` on track points. The compiled header's dates and durations
//    describe when distributors actually walked; a hand-drawn line has no
//    such time, and inventing one (now) would move the report's dates.
//  * File names. The client's fallback loader (used before the compiled JSON
//    exists) sorts files by name — "waypoint" in the name means waypoints,
//    anything else means tracks — so a drawn track must never contain it and
//    a drawn waypoint must.
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A single-waypoint GPX document.
String drawnWaypointGpx({
  required String name,
  String description = '',
  required LatLng position,
}) {
  final b = StringBuffer(_header)
    ..write('  <wpt lat="${_coord(position.latitude)}" '
        'lon="${_coord(position.longitude)}">\n')
    ..write('    <name>${_escape(name)}</name>\n');
  if (description.isNotEmpty) {
    b.write('    <desc>${_escape(description)}</desc>\n');
  }
  b
    ..write('  </wpt>\n')
    ..write(_footer);
  return b.toString();
}

/// A single-track, single-segment GPX document.
String drawnTrackGpx({
  required String name,
  String description = '',
  required List<LatLng> points,
}) {
  final b = StringBuffer(_header)
    ..write('  <trk>\n')
    ..write('    <name>${_escape(name)}</name>\n');
  if (description.isNotEmpty) {
    b.write('    <desc>${_escape(description)}</desc>\n');
  }
  b.write('    <trkseg>\n');
  for (final p in points) {
    b.write('      <trkpt lat="${_coord(p.latitude)}" '
        'lon="${_coord(p.longitude)}"/>\n');
  }
  b
    ..write('    </trkseg>\n')
    ..write('  </trk>\n')
    ..write(_footer);
  return b.toString();
}

/// File name for a drawn element. [isWaypoint] decides which of the two
/// loader buckets it lands in — see the note at the top of this file.
String drawnGpxFileName({
  required bool isWaypoint,
  required String name,
  required DateTime at,
}) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  // Drop "waypoint" from a track's slug too: a track named "Waypoint route"
  // must not be misfiled by the name-based fallback loader.
  final safeSlug = isWaypoint ? slug : slug.replaceAll('waypoint', 'wpt');
  final kind = isWaypoint ? 'drawn_waypoint' : 'drawn_track';
  final stamp = at.millisecondsSinceEpoch;
  return safeSlug.isEmpty
      ? '${kind}_$stamp.gpx'
      : '${kind}_${safeSlug}_$stamp.gpx';
}

const _header = '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<gpx version="1.1" creator="CLM Maps" '
    'xmlns="http://www.topografix.com/GPX/1/1">\n';
const _footer = '</gpx>\n';

String _coord(double v) => v.toStringAsFixed(7);

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
