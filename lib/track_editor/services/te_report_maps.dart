// track_editor/services/te_report_maps.dart
//
// The maps of each promoter's day for the client report: the route they
// walked over a Google street map. Each map is half the page wide and
// zoomed in on one position the promoter worked — where their flyers went
// out — and two positions get two maps side by side. The flyers themselves
// aren't drawn; the route says enough.
//
// Only the plain street map comes from Google (Static Maps API, no
// overlays); the route is drawn on top in the PDF as vectors. That keeps it
// crisp at any zoom, carries the whole route rather than the few points a
// Static Maps URL has room for, and still prints it on a blank background
// when the street map can't be fetched.
//
// The PDF and the fetch must agree on exactly where each map sits, so both
// work it out from [teReportMaps] — the same Web Mercator maths Google uses:
// at zoom z the world is 256·2^z pixels wide, and the image's centre pixel
// is [TEMapFrame]'s centre.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:gpx/gpx.dart';
import 'package:http/http.dart' as http;

import '../../shareable_maps/services/map_thumbnail_service.dart';
import '../models/te_promoter_day.dart';

/// Map size in Static Maps pixels (the image comes back at twice this, about
/// 180 dpi at half the page width — sharp in print, small in the file).
/// 16:10, a little wider than tall.
const int teMapWidth = 320;
const int teMapHeight = 200;

/// Most maps per promoter: two fit side by side.
const int teMaxMapsPerPromoter = 2;

/// Flyers further apart than this were handed out at different positions.
const double _positionGapM = 300;

/// Consecutive fixes further apart than this are a GPS jump or a logger that
/// was off while driving — the route breaks there instead of drawing a
/// straight line across the suburb.
const double _breakAfterM = 250;

/// A promoter's day for the maps: the route walked, in time order and
/// broken at gaps (drawn), and where each flyer was handed out (which
/// positions the maps zoom in on).
class TEMapRoute {
  final List<List<(double, double)>> segments;
  final List<(double, double)> flyers;

  const TEMapRoute({required this.segments, required this.flyers});

  bool get isEmpty => segments.isEmpty && flyers.isEmpty;

  Iterable<(double, double)> get allPoints sync* {
    for (final s in segments) {
      yield* s;
    }
    yield* flyers;
  }
}

/// The route and flyers of [day]. Two rounds on the same day are merged into
/// one time-ordered route.
TEMapRoute teMapRoute(TEPromoterDay day) {
  final fixes = <(DateTime?, double, double)>[];
  for (final trk in day.tracks) {
    for (final seg in trk.trksegs) {
      for (final p in seg.trkpts) {
        if (!_hasPosition(p)) continue;
        fixes.add((p.time, p.lat!, p.lon!));
      }
    }
  }
  // Rounds recorded in separate files go into time order. A file without
  // times keeps the order it was written in.
  if (fixes.every((f) => f.$1 != null)) {
    fixes.sort((a, b) => a.$1!.compareTo(b.$1!));
  }

  final segments = <List<(double, double)>>[];
  List<(double, double)>? current;
  for (final f in fixes) {
    final p = (f.$2, f.$3);
    if (current == null || teMetres(current.last, p) > _breakAfterM) {
      current = [p];
      segments.add(current);
    } else {
      current.add(p);
    }
  }
  // A lone fix between two jumps is noise, not a route.
  segments.removeWhere((s) => s.length < 2);

  return TEMapRoute(
    segments: segments,
    flyers: [
      for (final w in day.waypoints)
        if (_hasPosition(w)) (w.lat!, w.lon!),
    ],
  );
}

/// One place a promoter stood and handed out flyers — in practice an
/// intersection.
class TEMapPosition {
  final List<(double, double)> flyers;
  const TEMapPosition(this.flyers);

  (double, double) get centre => (
        flyers.fold<double>(0, (s, p) => s + p.$1) / flyers.length,
        flyers.fold<double>(0, (s, p) => s + p.$2) / flyers.length,
      );
}

/// The positions [route]'s flyers were handed out at, busiest first. A
/// position needs a real share of the day — at least 10 flyers and 5% of
/// them — so a few presses while walking between corners don't get a map of
/// their own; a day with none that large keeps its busiest.
List<TEMapPosition> teMapPositions(TEMapRoute route) {
  final clusters = <List<(double, double)>>[];
  final centres = <(double, double)>[];
  for (final f in route.flyers) {
    var i = centres.indexWhere((c) => teMetres(c, f) <= _positionGapM);
    if (i < 0) {
      clusters.add([]);
      centres.add(f);
      i = clusters.length - 1;
    }
    clusters[i].add(f);
    final n = clusters[i].length;
    centres[i] = (
      centres[i].$1 + (f.$1 - centres[i].$1) / n,
      centres[i].$2 + (f.$2 - centres[i].$2) / n,
    );
  }
  // A centre that drifted while its cluster grew can end up beside another.
  for (var merged = true; merged;) {
    merged = false;
    for (var i = 0; i < clusters.length && !merged; i++) {
      for (var j = i + 1; j < clusters.length; j++) {
        if (teMetres(centres[i], centres[j]) > _positionGapM) continue;
        clusters[i].addAll(clusters.removeAt(j));
        centres.removeAt(j);
        centres[i] = TEMapPosition(clusters[i]).centre;
        merged = true;
        break;
      }
    }
  }

  clusters.sort((a, b) => b.length.compareTo(a.length));
  final floor = math.max(10, (route.flyers.length * 0.05).ceil());
  final big = [
    for (final c in clusters)
      if (c.length >= floor) TEMapPosition(c),
  ];
  return big.isNotEmpty || clusters.isEmpty
      ? big
      : [TEMapPosition(clusters.first)];
}

/// One map in the report: where it sits, and the position it is zoomed in
/// on (null for a whole-route map of a day with no flyers).
class TEReportMap {
  final TEMapFrame frame;
  final TEMapPosition? position;
  const TEReportMap(this.frame, this.position);
}

/// The maps for a promoter's day: one per position worked, busiest first
/// and at most [teMaxMapsPerPromoter], each zoomed in on its position; or
/// one map of the whole route when no flyer has a position.
List<TEReportMap> teReportMaps(TEMapRoute route) {
  final positions = teMapPositions(route);
  if (positions.isEmpty) {
    final frame = teMapFrame(route.allPoints);
    return frame == null ? const [] : [TEReportMap(frame, null)];
  }
  return [
    for (final p in positions.take(teMaxMapsPerPromoter))
      TEReportMap(teMapFrame(p.flyers)!, p),
  ];
}

/// Key of [day]'s map number [index] in [fetchReportMaps]'s result.
String teReportMapKey(TEPromoterDay day, int index) => '${day.key}#$index';

/// The gpx package reads a missing position as 0,0 — in the sea off West
/// Africa, never a real fix.
bool _hasPosition(Wpt p) =>
    p.lat != null && p.lon != null && !(p.lat == 0 && p.lon == 0);

/// Where a map sits: its centre in normalised Web Mercator (0–1 across the
/// world), its zoom, and its size in Static Maps pixels.
class TEMapFrame {
  final double centreX;
  final double centreY;
  final int zoom;
  final int width;
  final int height;

  const TEMapFrame({
    required this.centreX,
    required this.centreY,
    required this.zoom,
    this.width = teMapWidth,
    this.height = teMapHeight,
  });

  double get _world => 256.0 * (1 << zoom);

  /// [lat],[lon] as a pixel on the map, origin top-left.
  (double, double) toPixel(double lat, double lon) => (
        (_mercX(lon) - centreX) * _world + width / 2,
        (_mercY(lat) - centreY) * _world + height / 2,
      );

  LatLng get centre => LatLng(_latOf(centreY), centreX * 360 - 180);

  /// The plain street map for this frame, as a JPEG (a fraction of a PNG's
  /// size in the PDF). Road names stay on so the client can read the area.
  String get staticUrl => '${MapThumbnailService.buildThumbnailUrl(
        center: centre,
        zoom: zoom.toDouble(),
        width: width,
        height: height,
        detailedRoads: true,
      )}&format=jpg';
}

/// The closest zoom that fits all of [points] with a margin, or null when
/// there are none.
TEMapFrame? teMapFrame(Iterable<(double, double)> points,
    {int width = teMapWidth, int height = teMapHeight}) {
  if (points.isEmpty) return null;
  var minX = double.infinity, maxX = -double.infinity;
  var minY = double.infinity, maxY = -double.infinity;
  for (final (lat, lon) in points) {
    final x = _mercX(lon), y = _mercY(lat);
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }
  // 8% of each side kept clear, so markers at the edge aren't cut off.
  const pad = 0.84;
  var zoom = 17; // closest worth showing: a single street corner
  while (zoom > 3) {
    final world = 256.0 * (1 << zoom);
    if ((maxX - minX) * world <= width * pad &&
        (maxY - minY) * world <= height * pad) {
      break;
    }
    zoom--;
  }
  return TEMapFrame(
    centreX: (minX + maxX) / 2,
    centreY: (minY + maxY) / 2,
    zoom: zoom,
    width: width,
    height: height,
  );
}

/// Street-map images already fetched, by URL — regenerating a report
/// doesn't ask Google again.
final Map<String, Uint8List> _imageMemo = {};

/// The street map behind every map of [days] (see [teReportMaps]), keyed by
/// [teReportMapKey]. A map that can't be fetched is left out and its route
/// prints on a blank background. [onProgress] hears each map as it
/// finishes.
Future<Map<String, Uint8List>> fetchReportMaps(
  List<TEPromoterDay> days, {
  void Function(int done, int total)? onProgress,
}) async {
  final urls = <String, String>{};
  for (final d in days) {
    final maps = teReportMaps(teMapRoute(d));
    for (var i = 0; i < maps.length; i++) {
      urls[teReportMapKey(d, i)] = maps[i].frame.staticUrl;
    }
  }
  final out = <String, Uint8List>{};
  final keys = urls.keys.toList();
  var done = 0;
  onProgress?.call(0, keys.length);
  for (var i = 0; i < keys.length; i += 4) {
    await Future.wait([
      for (final key in keys.sublist(i, math.min(i + 4, keys.length)))
        _fetch(urls[key]!).then((bytes) {
          if (bytes != null) out[key] = bytes;
          onProgress?.call(++done, keys.length);
        }),
    ]);
  }
  return out;
}

Future<Uint8List?> _fetch(String url) async {
  final memo = _imageMemo[url];
  if (memo != null) return memo;
  try {
    final res =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    final type = res.headers['content-type'] ?? '';
    if (res.statusCode != 200 || !type.startsWith('image/')) {
      debugPrint('Report map: HTTP ${res.statusCode} $type');
      return null;
    }
    return _imageMemo[url] = res.bodyBytes;
  } catch (e) {
    debugPrint('Report map failed: $e');
    return null;
  }
}

double _mercX(double lon) => (lon + 180) / 360;

double _mercY(double lat) {
  final s = math.sin(lat.clamp(-85.0, 85.0) * math.pi / 180);
  return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
}

double _latOf(double y) =>
    90 - 360 * math.atan(math.exp((y - 0.5) * 2 * math.pi)) / math.pi;

/// Metres between two (lat, lon) points.
double teMetres((double, double) a, (double, double) b) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.$1 - a.$1);
  final dLon = rad(b.$2 - a.$2);
  final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(a.$1)) *
          math.cos(rad(b.$1)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(x)));
}
