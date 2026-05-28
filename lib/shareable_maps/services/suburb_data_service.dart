import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:xml/xml.dart';

import '../../models/work_suburb.dart';

/// Manages loading and saving Cape Town suburb polygons.
///
/// Architecture:
///   - Firestore `workSuburbs/main` holds the canonical `suburbs` array
///   - The editor loads this document directly
///   - Saves overwrite the full array so edits, additions and deletions all
///     live in Firestore
///   - Loaded suburbs are kept in-memory for the session
class SuburbDataService {
  static const String _mainPath = 'workSuburbs/main';

  final FirebaseFirestore _firestore;

  static List<WorkSuburb>? _cachedSuburbs;

  SuburbDataService({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  // ── Public API ───────────────────────────────────────────────────────────

  /// Non-null after the first successful [loadSuburbs] call.
  List<WorkSuburb>? get baseSuburbs => _cachedSuburbs;

  /// Returns the full list of suburbs from `workSuburbs/main`.
  ///
  /// Subsequent calls within the same session return immediately from the
  /// in-memory cache. Pass [forceRefresh] to bypass that cache.
  ///
  Future<List<WorkSuburb>> loadSuburbs({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedSuburbs != null) {
      return List<WorkSuburb>.from(_cachedSuburbs!);
    }

    final docRef = _firestore.doc(_mainPath);
    DocumentSnapshot<Map<String, dynamic>>? snap;
    try {
      snap = forceRefresh
          ? await docRef.get(const GetOptions(source: Source.server))
          : await docRef.get();
    } catch (e) {
      debugPrint('SuburbDataService: Firestore fetch failed: $e');
      try {
        snap = await docRef.get(const GetOptions(source: Source.cache));
      } catch (cacheError) {
        debugPrint(
            'SuburbDataService: Firestore cache fetch failed: $cacheError');
      }
    }

    final suburbs = _suburbsFromSnapshot(snap);
    _cachedSuburbs = suburbs;
    debugPrint(
        'SuburbDataService: loaded ${suburbs.length} suburbs from Firestore');
    return List<WorkSuburb>.from(suburbs);
  }

  /// Overwrite the canonical `workSuburbs/main.suburbs` array.
  Future<void> saveSuburbs(List<WorkSuburb> current) async {
    await _firestore.doc(_mainPath).set({
      'suburbs': current.map((suburb) => suburb.toMap()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    _cachedSuburbs = List<WorkSuburb>.from(current);
    debugPrint(
        'SuburbDataService: saved ${current.length} suburbs to Firestore');
  }

  /// Clear the in-memory cache, forcing a fresh Firestore read on the next call.
  static void invalidateCache() {
    _cachedSuburbs = null;
  }

  // ── Internal helpers ─────────────────────────────────────────────────────

  static List<WorkSuburb> _suburbsFromSnapshot(
    DocumentSnapshot<Map<String, dynamic>>? snap,
  ) {
    if (snap == null || !snap.exists) return <WorkSuburb>[];
    final data = snap.data();
    if (data == null) return <WorkSuburb>[];
    final raw = data['suburbs'] as List<dynamic>? ?? const [];
    return raw
        .map((entry) =>
            WorkSuburb.fromMap(Map<String, dynamic>.from(entry as Map)))
        .toList();
  }

  /// Parse a KML string into a list of [WorkSuburb].
  ///
  /// KML coordinate order is `longitude,latitude[,altitude]` — this method
  /// correctly swaps them to `LatLng(lat, lng)`.
  ///
  /// Runs in a [Future] so the caller yields to the event loop before blocking
  /// on the CPU-bound XML parse (important for UI responsiveness).
  static Future<List<WorkSuburb>> parseKml(String kmlStr) {
    return Future(() => parseKmlSync(kmlStr));
  }

  static List<WorkSuburb> parseKmlSync(String kmlStr) {
    final document = XmlDocument.parse(kmlStr);
    final placemarks = document.findAllElements('Placemark');

    return placemarks.map((pm) {
      final name = pm.findElements('name').firstOrNull?.innerText.trim() ?? '';
      final description =
          pm.findElements('description').firstOrNull?.innerText.trim() ?? '';

      // Coordinates element: one entry per outer boundary ring.
      final coordsText =
          pm.findAllElements('coordinates').firstOrNull?.innerText.trim() ?? '';

      final points = <LatLng>[];
      if (coordsText.isNotEmpty) {
        for (final token in coordsText.split(RegExp(r'\s+'))) {
          if (token.isEmpty) continue;
          final parts = token.split(',');
          if (parts.length >= 2) {
            final lng = double.tryParse(parts[0]);
            final lat = double.tryParse(parts[1]);
            if (lng != null && lat != null) {
              points.add(LatLng(lat, lng)); // KML = lng,lat → flip
            }
          }
        }
      }

      return WorkSuburb(
        id: description.isNotEmpty ? description : _fallbackId(name),
        name: name,
        description: '',
        polygonPoints: points,
        color: WorkSuburb.defaultColor,
      );
    }).toList();
  }

  static String _fallbackId(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return slug.isEmpty ? 'suburb' : slug;
  }

  // ── Serialisation helpers (used by seeder) ────────────────────────────────

  /// Convert a [WorkSuburb] to a plain JSON-safe map (no GeoPoint — useful
  /// for file-based caching or seeding).
  static Map<String, dynamic> suburbToJson(WorkSuburb s) => {
        'id': s.id,
        'name': s.name,
        'description': s.description,
        'letterBoxEstimate': s.letterBoxEstimate,
        'color': s.color.toARGB32(),
        'polygonPoints': s.polygonPoints
            .map((p) => {'lat': p.latitude, 'lng': p.longitude})
            .toList(),
      };

  /// Reconstruct a [WorkSuburb] from a [suburbToJson] map.
  static WorkSuburb suburbFromJson(Map<String, dynamic> m) => WorkSuburb(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        description: m['description'] as String? ?? '',
        letterBoxEstimate: (m['letterBoxEstimate'] as num?)?.toInt() ?? 0,
        color: Color(
          (m['color'] as num?)?.toInt() ?? WorkSuburb.defaultColor.toARGB32(),
        ),
        polygonPoints: (m['polygonPoints'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map((p) => LatLng(
                  (p['lat'] as num).toDouble(),
                  (p['lng'] as num).toDouble(),
                ))
            .toList(),
      );
}
