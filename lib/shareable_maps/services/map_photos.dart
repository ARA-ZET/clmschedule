// shareable_maps/services/map_photos.dart
//
// Photos taken at a map's waypoints (clmgpx "Poster 501", "Delivery point
// 12" …), for the waypoint's info window. Read from the photos page's index
// (/photos/{shareCode}/index.json), so the map only ever sees our own photo
// URLs — never a Storage address.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'map_link_service.dart';

/// One photo of a map's gallery.
class MapPhoto {
  final String id;

  /// Distributor, from the clmgpx file name ("Petros").
  final String who;

  /// The waypoint it was taken for ("Poster 501").
  final String what;

  /// `yyyy-MM-dd` and `HH:mm:ss` from the file name; empty when absent.
  final String date;
  final String time;

  /// Absolute URLs on the photos host.
  final String thumbUrl;
  final String fullUrl;
  final String downloadUrl;

  const MapPhoto({
    required this.id,
    required this.who,
    required this.what,
    required this.date,
    required this.time,
    required this.thumbUrl,
    required this.fullUrl,
    required this.downloadUrl,
  });

  factory MapPhoto.fromJson(Map<String, dynamic> j, String origin) {
    String s(String k) => j[k] is String ? j[k] as String : '';
    String abs(String path) => path.startsWith('http') ? path : '$origin$path';
    return MapPhoto(
      id: s('id'),
      who: s('who'),
      what: s('what'),
      date: s('date'),
      time: s('time'),
      thumbUrl: abs(s('thumb')),
      fullUrl: abs(s('src')),
      downloadUrl: abs(s('download')),
    );
  }
}

/// A map's photos, and which one belongs to a waypoint.
class MapPhotoIndex {
  final List<MapPhoto> photos;

  const MapPhotoIndex(this.photos);

  static const empty = MapPhotoIndex([]);

  MapPhoto? forWaypoint(String waypointName, String sourceFile) =>
      matchWaypointPhoto(waypointName, sourceFile, photos);
}

/// Lowercase words only, so "Poster 501" and "poster-501" agree.
String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

const _months = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

/// `yyyy-MM-dd` from a track file name's "22 Oct 2026", or ''.
String _fileDate(String fileName) {
  final m = RegExp(r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})').firstMatch(fileName);
  if (m == null) return '';
  final month = _months.indexOf(m.group(2)!.toLowerCase());
  if (month < 0) return '';
  final d = m.group(1)!.padLeft(2, '0');
  return '${m.group(3)}-${(month + 1).toString().padLeft(2, '0')}-$d';
}

/// The distributor a track file names ("Track   22 Oct 2026   Petros   …").
String _fileWho(String fileName) {
  final parts = fileName.split(RegExp(r'\s{3,}'));
  return parts.length >= 4 && _fileDate(parts[1]).isNotEmpty ? parts[2] : '';
}

/// The photo taken at a waypoint, or null.
///
/// clmgpx names a photo after its waypoint and its distributor
/// (`Petros_Poster 501_2026-10-22_12-37-26.jpg`), while the waypoint comes
/// from a track file naming the distributor and the day. Waypoint numbers
/// restart each session, so the name alone can match several photos; the
/// distributor and then the day narrow it to one. Should two still match
/// (a photo taken again), the later one wins.
@visibleForTesting
MapPhoto? matchWaypointPhoto(
  String waypointName,
  String sourceFile,
  List<MapPhoto> photos,
) {
  final name = _norm(waypointName);
  if (name.isEmpty) return null;
  var candidates = photos.where((p) => _norm(p.what) == name).toList();
  if (candidates.isEmpty) return null;

  final whoWords = _norm(_fileWho(sourceFile)).split(' ').where((w) => w.isNotEmpty).toSet();
  if (whoWords.isNotEmpty) {
    final byWho = candidates
        .where((p) => _norm(p.who).split(' ').any(whoWords.contains))
        .toList();
    if (byWho.isNotEmpty) candidates = byWho;
  }

  final day = _fileDate(sourceFile);
  if (day.isNotEmpty && candidates.length > 1) {
    final byDay = candidates.where((p) => p.date == day).toList();
    if (byDay.isNotEmpty) candidates = byDay;
  }

  candidates.sort((a, b) => '${b.date} ${b.time}'.compareTo('${a.date} ${a.time}'));
  return candidates.first;
}

/// Reads a map's photo index from the photos host.
class MapPhotosService {
  final http.Client? _client;

  MapPhotosService({http.Client? client}) : _client = client;

  /// The index for [shareCode]; empty when the map has no photos, or when
  /// the index cannot be read (the info window then just has no photo).
  Future<MapPhotoIndex> load(String shareCode) async {
    final origin = 'https://${MapLinkService.shareHost}';
    try {
      final uri = Uri.parse('$origin/photos/${Uri.encodeComponent(shareCode)}/index.json');
      final res = await (_client?.get(uri) ?? http.get(uri));
      if (res.statusCode != 200) return MapPhotoIndex.empty;
      final list = (jsonDecode(res.body) as Map)['photos'];
      if (list is! List) return MapPhotoIndex.empty;
      return MapPhotoIndex([
        for (final p in list)
          if (p is Map) MapPhoto.fromJson(Map<String, dynamic>.from(p), origin),
      ]);
    } catch (e) {
      debugPrint('[MapPhotos] index for $shareCode failed: $e');
      return MapPhotoIndex.empty;
    }
  }
}
