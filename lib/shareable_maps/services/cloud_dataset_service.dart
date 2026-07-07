import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

/// Metadata for a Google Maps Platform Dataset linked to a Cloud Storage
/// folder. Written by the Cloud Function that compiles `_compiled_waypoints.json`.
///
/// Firestore path: `cloudDatasets/{folderHash}`
class CloudDatasetMeta {
  final String datasetId;
  final String folderPath;
  final int featureCount;
  final DateTime? updatedAt;

  const CloudDatasetMeta({
    required this.datasetId,
    required this.folderPath,
    required this.featureCount,
    this.updatedAt,
  });

  factory CloudDatasetMeta.fromMap(Map<String, dynamic> map, String folderPath) {
    final ts = map['updatedAt'];
    return CloudDatasetMeta(
      datasetId: map['datasetId'] as String,
      folderPath: folderPath,
      featureCount: (map['featureCount'] as num?)?.toInt() ?? 0,
      updatedAt: ts is Timestamp ? ts.toDate() : null,
    );
  }
}

/// Reads [CloudDatasetMeta] from Firestore.
class CloudDatasetService {
  static const _collection = 'cloudDatasets';

  final FirebaseFirestore _db;

  CloudDatasetService({FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  static String folderHash(String folderPath) {
    return folderPath
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
  }

  Future<CloudDatasetMeta?> getDatasetMeta(String folderPath) async {
    try {
      final doc = await _db
          .collection(_collection)
          .doc(folderHash(folderPath))
          .get();
      if (!doc.exists || doc.data() == null) return null;
      return CloudDatasetMeta.fromMap(doc.data()!, folderPath);
    } catch (e) {
      debugPrint('[CloudDatasetService] getDatasetMeta failed: $e');
      return null;
    }
  }

  /// Calls the `syncWaypointDataset` Cloud Function to create a Maps Platform
  /// Dataset for [folderPath]. Returns the new dataset ID on success, null on
  /// failure. The CF writes to Firestore before returning so a subsequent
  /// [getDatasetMeta] call will find the doc.
  Future<String?> triggerDatasetCreation(String folderPath) async {
    try {
      final callable = FirebaseFunctions.instance
          .httpsCallable('syncWaypointDataset');
      final result = await callable.call<Map<String, dynamic>>(
          {'folderPath': folderPath});
      return result.data['datasetId'] as String?;
    } catch (e) {
      debugPrint('[CloudDatasetService] triggerDatasetCreation failed: $e');
      return null;
    }
  }
}

/// [TileProvider] that fetches PNG tiles for a Google Maps Platform Dataset.
///
/// Tile URL: `https://tile.googleapis.com/v1/datasets/{id}/tiles/{z}/{x}/{y}?key=…`
///
/// Design notes:
/// • A single long-lived [http.Client] is shared across all tile requests for
///   this provider instance. On web (including `--wasm`) the client reuses the
///   browser's HTTP connection pool, which avoids the latency of a new TCP/TLS
///   handshake per tile and closes any inter-tile gaps caused by slow fetches.
/// • `fadeIn` is set to false on the [TileOverlay] that owns this provider so
///   tiles snap in immediately — the fade-in animation creates a visible blank
///   flash between adjacent tiles on high-DPI screens and in `--wasm` builds.
/// • WASM compatibility: uses only `package:http` (no `dart:html` / `dart:io`).
///   The `http` package routes through `dart:js_interop` Fetch API on WASM,
///   the same as on standard Flutter web builds.
class DatasetTileProvider extends TileProvider {
  final String datasetId;
  final String apiKey;

  static const _baseUrl = 'https://tile.googleapis.com/v1/datasets';

  // Shared client: connection pool is reused across tile fetches so adjacent
  // tiles arrive in quick succession and appear seamless.
  final http.Client _client;

  DatasetTileProvider({
    required this.datasetId,
    required this.apiKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<Tile> getTile(int x, int y, int? zoom) async {
    final z = zoom ?? 0;
    final uri = Uri.parse('$_baseUrl/$datasetId/tiles/$z/$x/$y?key=$apiKey');
    try {
      final response =
          await _client.get(uri).timeout(const Duration(seconds: 8));
      // response.bodyBytes is already a Uint8List — no copy needed.
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        return Tile(256, 256, response.bodyBytes);
      }
    } catch (_) {}
    // Return an empty transparent tile rather than noTile so the map does not
    // fall back to the basemap and reveal a gap while the real tile loads.
    return _emptyTile;
  }

  /// 1×1 transparent PNG — used as a placeholder so the map renders a blank
  /// tile instead of exposing the underlying basemap layer during fetch.
  static final Tile _emptyTile = Tile(
    1,
    1,
    Uint8List.fromList(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, // IDAT chunk
      0x54, 0x78, 0x9C, 0x62, 0x00, 0x00, 0x00, 0x02,
      0x00, 0x01, 0xE2, 0x21, 0xBC, 0x33, 0x00, 0x00, // IEND chunk
      0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
      0x60, 0x82,
    ]),
  );
}
