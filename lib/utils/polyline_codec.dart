import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Decode a Google "encoded polyline algorithm" string into points.
///
/// Shared by every caller that reads a Directions response so the
/// bit-shift loop lives in exactly one place.
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0;
  final len = encoded.length;
  var lat = 0;
  var lng = 0;

  while (index < len) {
    var shift = 0;
    var result = 0;
    int byte;

    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && index < len);
    lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    shift = 0;
    result = 0;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && index < len);
    lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    points.add(LatLng(lat / 1E5, lng / 1E5));
  }

  return points;
}

/// Drop points that sit within [toleranceMeters] of the line between
/// their neighbours (Ramer–Douglas–Peucker).
///
/// A 200-stop route carries tens of thousands of polyline points; KML
/// files and map layers stay readable if the visually redundant ones are
/// removed first.
List<LatLng> simplifyPath(List<LatLng> points, {double toleranceMeters = 5}) {
  if (points.length < 3) return points;

  final keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;

  final stack = <List<int>>[
    [0, points.length - 1]
  ];
  while (stack.isNotEmpty) {
    final range = stack.removeLast();
    final first = range[0];
    final last = range[1];
    if (last <= first + 1) continue;

    var maxDist = 0.0;
    var maxIndex = first;
    for (var i = first + 1; i < last; i++) {
      final d = _perpendicularDistance(points[i], points[first], points[last]);
      if (d > maxDist) {
        maxDist = d;
        maxIndex = i;
      }
    }

    if (maxDist > toleranceMeters) {
      keep[maxIndex] = true;
      stack.add([first, maxIndex]);
      stack.add([maxIndex, last]);
    }
  }

  return [
    for (var i = 0; i < points.length; i++)
      if (keep[i]) points[i],
  ];
}

/// Approximate metres from [p] to the segment [a]–[b], using a local
/// equirectangular projection — accurate enough at street scale.
double _perpendicularDistance(LatLng p, LatLng a, LatLng b) {
  const metresPerDegLat = 111320.0;
  final cosLat = math.cos(a.latitude * math.pi / 180);

  final ax = 0.0;
  final ay = 0.0;
  final bx = (b.longitude - a.longitude) * metresPerDegLat * cosLat;
  final by = (b.latitude - a.latitude) * metresPerDegLat;
  final px = (p.longitude - a.longitude) * metresPerDegLat * cosLat;
  final py = (p.latitude - a.latitude) * metresPerDegLat;

  final dx = bx - ax;
  final dy = by - ay;
  final lenSq = dx * dx + dy * dy;
  if (lenSq == 0) return _hypot(px, py);

  var t = (px * dx + py * dy) / lenSq;
  t = t.clamp(0.0, 1.0);
  return _hypot(px - dx * t, py - dy * t);
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);
