// services/job_cloud_map_data_service.dart
//
// Fetches compiled GPS tracks for an already-known Cloud Storage folder, and
// matches a schedule Job's clients against the pool of "unfinished" (gap)
// work-area polygons — the same matching rule used to build the
// `kUnfinishedAreasLayerId` overlay layer in the Shareable Map editor.
import 'package:flutter/foundation.dart' show compute;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../providers/unfinished_work_areas_provider.dart';
import '../shareable_maps/models/map_polyline.dart';
import 'compiled_tracks_parser.dart';
import 'gpx_storage_service.dart';

/// Result of matching a job's clients against the unfinished work-area pool.
class GapAreaMatch {
  final List<CustomPolygon> polygons;

  /// Polygon name -> source `unfinishedWorkAreas` doc id, so edits can be
  /// routed back to the correct pooled item.
  final Map<String, String> polygonNameToItemId;

  const GapAreaMatch({
    required this.polygons,
    required this.polygonNameToItemId,
  });

  static const empty = GapAreaMatch(polygons: [], polygonNameToItemId: {});
}

class JobCloudMapDataService {
  final GpxStorageService _storage;

  JobCloudMapDataService({GpxStorageService? storage})
      : _storage = storage ?? GpxStorageService();

  /// Fetch and parse the compiled tracks file for [folderPath]. Returns an
  /// empty list if it hasn't been compiled yet (no GPX fallback — this path
  /// is meant to be light; the fallback lives in [ShareableMapProvider] for
  /// the full map editor).
  Future<List<MapPolyline>> fetchCompiledTracks(String folderPath) async {
    final bytes =
        await _storage.downloadFileBytes('$folderPath/_compiled_tracks.json');
    if (bytes == null) return [];
    return compute(parseCompiledTracksBytes, bytes);
  }

  /// Match [job]'s clients against the pooled unfinished work areas
  /// (case-insensitive, trimmed overlap on client name) — the same matching
  /// rule used to build the `kUnfinishedAreasLayerId` overlay layer in the
  /// Shareable Map editor.
  static GapAreaMatch matchingGapAreas(
    Job job,
    UnfinishedWorkAreasProvider unfinished,
  ) {
    if (job.clients.isEmpty) return GapAreaMatch.empty;

    final jobClients = job.clients.map((c) => c.trim().toLowerCase()).toSet();
    final polygons = <CustomPolygon>[];
    final polygonNameToItemId = <String, String>{};

    for (final item in unfinished.items) {
      final itemClientsNorm =
          item.clients.map((c) => c.trim().toLowerCase()).toList();
      final hasMatch = itemClientsNorm.any(jobClients.contains);
      if (!hasMatch) continue;

      for (final wm in item.workMaps.where((p) => p.isPolygon)) {
        if (wm.name.isEmpty) continue;
        polygons.add(wm.copyWith(points: List<LatLng>.from(wm.points)));
        polygonNameToItemId[wm.name] = item.id;
      }
    }

    return GapAreaMatch(
      polygons: polygons,
      polygonNameToItemId: polygonNameToItemId,
    );
  }
}
