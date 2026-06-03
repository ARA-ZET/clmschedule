import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../models/work_suburb.dart';

/// Manages loading and saving Cape Town suburb polygons.
///
/// Architecture:
///   - Firebase Storage holds the canonical KML at `suburbs/Cape_Town_Suburbs.kml`
///   - Firestore `workSuburbs/meta` holds: { version, storagePath, updatedAt }
///   - Firestore `workSuburbs/overrides` holds a **delta** on top of the KML:
///       deletedIds      — suburb IDs removed by the user
///       editedPolygons  — suburbs whose coordinates were changed
///       addedPolygons   — new polygons drawn by the user (not in KML)
///       metaOverrides   — letterBoxEstimate / description edits only
///   - Parsed base suburbs are kept in-memory for the session
///   - Falls back to the bundled asset if Storage is unreachable
class SuburbDataService {
  static const String _metaPath = 'workSuburbs/meta';
  static const String _overridesPath = 'workSuburbs/overrides';
  static const String _fallbackAsset = 'assets/maps/Cape_Town_Suburbs.kml';

  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;

  // Base suburbs parsed from the KML — no delta applied.
  static List<WorkSuburb>? _baseSuburbs;
  static String? _cachedVersion;

  SuburbDataService({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  // ── Public API ───────────────────────────────────────────────────────────

  /// The raw KML suburbs without any delta applied.  Non-null after the first
  /// successful [loadSuburbs] call.  Used by the adapter to compute deltas on
  /// save.
  List<WorkSuburb>? get baseSuburbs => _baseSuburbs;

  /// Returns the full list of suburbs with the delta applied (deletions,
  /// coordinate edits, additions, metadata overrides).
  ///
  /// On the first call the KML is downloaded and parsed.  Subsequent calls
  /// within the same session return immediately from the in-memory base and
  /// apply the Firestore-cached delta.
  ///
  /// Pass [forceRefresh] to bypass the in-memory KML cache and re-download.
  Future<List<WorkSuburb>> loadSuburbs({bool forceRefresh = false}) async {
    // 1. Read meta document for the current version tag.
    String? version;
    String? storagePath;
    try {
      final snap = await _firestore.doc(_metaPath).get();
      if (snap.exists) {
        final data = snap.data() as Map<String, dynamic>;
        version = data['version'] as String?;
        storagePath = data['storagePath'] as String?;
      }
    } catch (e) {
      debugPrint('SuburbDataService: meta fetch failed: $e');
    }

    // 2. Return in-memory KML cache when version matches (delta still applied fresh).
    if (!forceRefresh && _baseSuburbs != null && _cachedVersion == version) {
      return _applyDelta(_baseSuburbs!);
    }

    // 3. Download KML from Firebase Storage.
    List<WorkSuburb> suburbs = [];
    if (storagePath != null && storagePath.isNotEmpty) {
      try {
        final url = await _storage.ref(storagePath).getDownloadURL();
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          suburbs = await _parseKml(response.body);
          debugPrint(
              'SuburbDataService: loaded ${suburbs.length} suburbs from Storage');
        } else {
          debugPrint('SuburbDataService: Storage HTTP ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('SuburbDataService: Storage download failed: $e');
      }
    }

    // 4. Fallback to bundled KML asset.
    if (suburbs.isEmpty) {
      try {
        final kmlStr = await rootBundle.loadString(_fallbackAsset);
        suburbs = await _parseKml(kmlStr);
        debugPrint(
            'SuburbDataService: loaded ${suburbs.length} suburbs from bundle');
      } catch (e) {
        debugPrint('SuburbDataService: bundle fallback failed: $e');
      }
    }

    _baseSuburbs = suburbs;
    _cachedVersion = version;
    return _applyDelta(suburbs);
  }

  /// Compute and persist the delta between [current] (from the editor) and the
  /// cached base KML suburbs:
  ///
  ///   - **deletedIds**: base suburbs missing from [current]
  ///   - **editedPolygons**: base suburbs whose coordinates changed
  ///   - **addedPolygons**: [current] entries with no matching base suburb
  ///   - **metaOverrides**: non-default letterBoxEstimate / description
  ///
  /// [current] must carry actual polygon points (not empty lists).
  Future<void> saveDelta(List<WorkSuburb> current) async {
    final base = _baseSuburbs ?? [];
    final baseById = {for (final s in base) s.id: s};

    final currentIds = {for (final s in current) s.id};

    // Suburbs in base that are no longer in the editor.
    final deletedIds =
        base.where((s) => !currentIds.contains(s.id)).map((s) => s.id).toList();

    // New polygons drawn by the user — not present in the KML.
    final addedPolygons = current
        .where((s) => !baseById.containsKey(s.id))
        .map((s) => s.toMap())
        .toList();

    // Base suburbs whose polygon points were modified.
    final editedPolygons = current
        .where((s) {
          final orig = baseById[s.id];
          if (orig == null) return false; // it's an addition, not an edit
          return !_pointsEqual(s.polygonPoints, orig.polygonPoints);
        })
        .map((s) => s.toMap())
        .toList();

    // Metadata-only changes (letterBoxEstimate / description).
    final metaOverrides = current
        .where((s) => baseById.containsKey(s.id))
        .where((s) => s.letterBoxEstimate != 0 || s.description.isNotEmpty)
        .map((s) => {
              'id': s.id,
              'letterBoxEstimate': s.letterBoxEstimate,
              'description': s.description,
            })
        .toList();

    await _firestore.doc(_overridesPath).set({
      'deletedIds': deletedIds,
      'editedPolygons': editedPolygons,
      'addedPolygons': addedPolygons,
      'metaOverrides': metaOverrides,
      'updatedAt': FieldValue.serverTimestamp(),
    });

    debugPrint('SuburbDataService: saved delta — '
        '${deletedIds.length} deleted, '
        '${editedPolygons.length} edited, '
        '${addedPolygons.length} added, '
        '${metaOverrides.length} meta overrides');
  }

  /// Clear the in-memory cache, forcing a fresh download on the next call.
  static void invalidateCache() {
    _baseSuburbs = null;
    _cachedVersion = null;
  }

  // ── Internal helpers ─────────────────────────────────────────────────────

  /// Quick structural equality check for two polygon point lists.
  /// Compares length + first/middle/last points to avoid a full O(n) scan.
  static bool _pointsEqual(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length) return false;
    if (a.isEmpty) return true;
    final mid = a.length ~/ 2;
    return a[0].latitude == b[0].latitude &&
        a[0].longitude == b[0].longitude &&
        a[mid].latitude == b[mid].latitude &&
        a[mid].longitude == b[mid].longitude &&
        a.last.latitude == b.last.latitude &&
        a.last.longitude == b.last.longitude;
  }

  // ── Delta application ────────────────────────────────────────────────────

  /// Read the overrides document and apply all delta fields to [base].
  Future<List<WorkSuburb>> _applyDelta(List<WorkSuburb> base) async {
    Map<String, dynamic> data = {};
    try {
      DocumentSnapshot snap;
      try {
        snap = await _firestore
            .doc(_overridesPath)
            .get(const GetOptions(source: Source.cache));
        if (!snap.exists) snap = await _firestore.doc(_overridesPath).get();
      } catch (_) {
        snap = await _firestore.doc(_overridesPath).get();
      }
      if (!snap.exists) return base;
      data = snap.data() as Map<String, dynamic>;
    } catch (_) {
      return base; // offline with no cache — serve base KML as-is
    }

    List<WorkSuburb> result = List.from(base);

    // 1. Apply deletions.
    final deletedIds =
        (data['deletedIds'] as List<dynamic>?)?.cast<String>().toSet() ?? {};
    if (deletedIds.isNotEmpty) {
      result = result.where((s) => !deletedIds.contains(s.id)).toList();
    }

    // 2. Replace coordinates for edited suburbs.
    final editedRaw = (data['editedPolygons'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    if (editedRaw.isNotEmpty) {
      final editedMap = {
        for (final e in editedRaw.map(WorkSuburb.fromMap)) e.id: e,
      };
      result = result.map((s) => editedMap[s.id] ?? s).toList();
    }

    // 3. Append user-added polygons.
    final addedRaw = (data['addedPolygons'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    if (addedRaw.isNotEmpty) {
      result.addAll(addedRaw.map(WorkSuburb.fromMap));
    }

    // 4. Apply metadata overrides.
    final metaRaw = (data['metaOverrides'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    if (metaRaw.isNotEmpty) {
      final metaMap = {for (final o in metaRaw) o['id'] as String: o};
      result = result.map((s) {
        final o = metaMap[s.id];
        if (o == null) return s;
        return s.copyWith(
          letterBoxEstimate:
              (o['letterBoxEstimate'] as num?)?.toInt() ?? s.letterBoxEstimate,
          description: o['description'] as String? ?? s.description,
        );
      }).toList();
    }

    // 5. Legacy: support old flat 'overrides' list written by the previous version.
    final legacyRaw = (data['overrides'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    if (legacyRaw.isNotEmpty) {
      final legacyMap = {for (final o in legacyRaw) o['id'] as String: o};
      result = result.map((s) {
        final o = legacyMap[s.id];
        if (o == null) return s;
        return s.copyWith(
          letterBoxEstimate:
              (o['letterBoxEstimate'] as num?)?.toInt() ?? s.letterBoxEstimate,
          description: o['description'] as String? ?? s.description,
        );
      }).toList();
    }

    return result;
  }

  /// Parse a KML string into a list of [WorkSuburb].
  ///
  /// KML coordinate order is `longitude,latitude[,altitude]` — this method
  /// correctly swaps them to `LatLng(lat, lng)`.
  ///
  /// Runs in a [Future] so the caller yields to the event loop before blocking
  /// on the CPU-bound XML parse (important for UI responsiveness).
  static Future<List<WorkSuburb>> _parseKml(String kmlStr) {
    return Future(() => _parseKmlSync(kmlStr));
  }

  static List<WorkSuburb> _parseKmlSync(String kmlStr) {
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
        id: description, // description holds the SL_OFC_SBRB_KEY from the KML
        name: name,
        description: '',
        polygonPoints: points,
      );
    }).toList();
  }

  // ── Serialisation helpers (used by seeder) ────────────────────────────────

  /// Convert a [WorkSuburb] to a plain JSON-safe map (no GeoPoint — useful
  /// for file-based caching or seeding).
  static Map<String, dynamic> suburbToJson(WorkSuburb s) => {
        'id': s.id,
        'name': s.name,
        'description': s.description,
        'letterBoxEstimate': s.letterBoxEstimate,
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
        polygonPoints: (m['polygonPoints'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map((p) => LatLng(
                  (p['lat'] as num).toDouble(),
                  (p['lng'] as num).toDouble(),
                ))
            .toList(),
      );
}
