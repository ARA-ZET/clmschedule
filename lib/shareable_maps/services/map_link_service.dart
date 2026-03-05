import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Service for managing shareable map deep-link codes.
///
/// Firestore structure:
/// ```
/// /mapLinks/{shareCode}
///   monthKey: String   // e.g. '03-2026'
///   mapId: String      // Firestore doc ID inside shareableMaps/{monthKey}/maps/
///   mapName: String    // For display purposes
///   createdAt: int     // millis since epoch
/// ```
///
/// This flat lookup collection allows resolving a map with a *single* Firestore
/// read, without loading all maps or knowing which month the map belongs to.
class MapLinkService {
  final FirebaseFirestore _firestore;

  MapLinkService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference get _links => _firestore.collection('mapLinks');

  // ---------------------------------------------------------------------------
  // Create / Delete
  // ---------------------------------------------------------------------------

  /// Generate a unique short share code and store the link pointer.
  ///
  /// Returns the generated share code (e.g. 'x7Kp2m').
  Future<String> createShareLink({
    required String monthKey,
    required String mapId,
    String mapName = '',
  }) async {
    // Check if a link already exists for this map
    final existing = await getShareCodeForMap(monthKey, mapId);
    if (existing != null) return existing;

    // Generate a unique code
    String code = _generateCode();
    int attempts = 0;
    while (attempts < 10) {
      final doc = await _links.doc(code).get();
      if (!doc.exists) break;
      code = _generateCode();
      attempts++;
    }

    await _links.doc(code).set({
      'monthKey': monthKey,
      'mapId': mapId,
      'mapName': mapName,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    debugPrint('[MapLinkService] Created share link: $code → $monthKey/$mapId');
    return code;
  }

  /// Delete the share link for a map.
  Future<void> deleteShareLink(String shareCode) async {
    await _links.doc(shareCode).delete();
    debugPrint('[MapLinkService] Deleted share link: $shareCode');
  }

  /// Delete all share links pointing to a map (by monthKey + mapId).
  Future<void> deleteLinksForMap(String monthKey, String mapId) async {
    final snapshot = await _links
        .where('monthKey', isEqualTo: monthKey)
        .where('mapId', isEqualTo: mapId)
        .get();
    for (final doc in snapshot.docs) {
      await doc.reference.delete();
    }
  }

  // ---------------------------------------------------------------------------
  // Resolve
  // ---------------------------------------------------------------------------

  /// Resolve a share code to its map coordinates.
  ///
  /// Returns `null` if the code doesn't exist.
  Future<MapLinkData?> resolveShareCode(String shareCode) async {
    final doc = await _links.doc(shareCode).get();
    if (!doc.exists) return null;
    final data = doc.data() as Map<String, dynamic>;
    return MapLinkData(
      shareCode: shareCode,
      monthKey: data['monthKey'] as String,
      mapId: data['mapId'] as String,
      mapName: data['mapName'] as String? ?? '',
    );
  }

  /// Find the share code for a specific map (if one exists).
  Future<String?> getShareCodeForMap(String monthKey, String mapId) async {
    final snapshot = await _links
        .where('monthKey', isEqualTo: monthKey)
        .where('mapId', isEqualTo: mapId)
        .limit(1)
        .get();
    if (snapshot.docs.isEmpty) return null;
    return snapshot.docs.first.id;
  }

  // ---------------------------------------------------------------------------
  // URL helpers
  // ---------------------------------------------------------------------------

  /// Build the full deep-link URL for a share code.
  ///
  /// Points to the standalone CLM Maps app at clm-maps.web.app.
  static String buildShareUrl(String shareCode) {
    return 'https://clm-maps.web.app/map/$shareCode';
  }

  /// Extract the share code from a deep-link path.
  ///
  /// Accepts paths like `/map/x7Kp2m` and returns `x7Kp2m`.
  static String? extractShareCode(String path) {
    final uri = Uri.tryParse(path);
    if (uri == null) return null;
    final segments = uri.pathSegments;
    if (segments.length == 2 && segments[0] == 'map') {
      return segments[1];
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Code generation
  // ---------------------------------------------------------------------------

  static const _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  static const _codeLength = 8;

  /// Generate a random alphanumeric code.
  static String _generateCode() {
    final rng = Random.secure();
    return String.fromCharCodes(
      Iterable.generate(
        _codeLength,
        (_) => _chars.codeUnitAt(rng.nextInt(_chars.length)),
      ),
    );
  }
}

/// Resolved data from a share code.
class MapLinkData {
  final String shareCode;
  final String monthKey;
  final String mapId;
  final String mapName;

  const MapLinkData({
    required this.shareCode,
    required this.monthKey,
    required this.mapId,
    required this.mapName,
  });
}
