// track_editor/models/tab_item.dart
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';
import 'styled_polygon.dart';

/// A drop-off point shown on the processing map. Sourced from the
/// schedule job's `dropOffPoint` so the user can see exactly where the
/// distributor was supposed to start/end the round.
class TEDropOffPoint {
  final String label;
  final LatLng position;
  final String? jobId;
  const TEDropOffPoint({
    required this.label,
    required this.position,
    this.jobId,
  });
}

class TETabItem {
  final String title;
  final List<TEStyledPolygon> polygons;
  final List<Trk> tracks;
  final List<Wpt> waypoints;
  final List<TETargetPolygon> targetPolygons;
  final List<TEDropOffPoint> dropOffPoints;
  final String? storageFolderPath;

  /// Distributor + date this tab was matched to, when opened from the
  /// processing flow. Used to refresh the tab against the schedule and
  /// to push edits (e.g. added work-area polygons) back onto the matching
  /// schedule jobs.
  final String? distributorId;
  final DateTime? trackDate;
  final List<String> jobIds;

  /// Full Cloud Storage path this tab was originally loaded from
  /// (e.g. `Distribution/2026/Apr 2026/Client/Round 1/Route1.gpx`).
  /// When set, the Track Editor can overwrite-save back to this exact file.
  final String? sourceStoragePath;

  /// Stable pairing key from `TEGpxMatchedPair.matchKey` for tabs opened
  /// through the processing flow. Used so that closing the tab can also
  /// drop the matching staged GPX file entries from the processing
  /// provider — otherwise re-picking a single new file would re-open the
  /// closed tabs alongside it.
  final String? matchKey;

  TETabItem({
    required this.title,
    required this.polygons,
    required this.tracks,
    required this.waypoints,
    required this.targetPolygons,
    this.dropOffPoints = const [],
    this.storageFolderPath,
    this.sourceStoragePath,
    this.matchKey,
    this.distributorId,
    this.trackDate,
    this.jobIds = const [],
  });

  /// Return a new [TETabItem] with selected fields overridden but the
  /// underlying mutable lists shared with the original tab. The caller
  /// must not mutate the lists they inherit if they want true isolation.
  TETabItem copyWith({
    String? title,
    List<TEStyledPolygon>? polygons,
    List<Trk>? tracks,
    List<Wpt>? waypoints,
    List<TETargetPolygon>? targetPolygons,
    List<TEDropOffPoint>? dropOffPoints,
    String? storageFolderPath,
    String? sourceStoragePath,
    String? matchKey,
    String? distributorId,
    DateTime? trackDate,
    List<String>? jobIds,
  }) {
    return TETabItem(
      title: title ?? this.title,
      polygons: polygons ?? this.polygons,
      tracks: tracks ?? this.tracks,
      waypoints: waypoints ?? this.waypoints,
      targetPolygons: targetPolygons ?? this.targetPolygons,
      dropOffPoints: dropOffPoints ?? this.dropOffPoints,
      storageFolderPath: storageFolderPath ?? this.storageFolderPath,
      sourceStoragePath: sourceStoragePath ?? this.sourceStoragePath,
      matchKey: matchKey ?? this.matchKey,
      distributorId: distributorId ?? this.distributorId,
      trackDate: trackDate ?? this.trackDate,
      jobIds: jobIds ?? this.jobIds,
    );
  }
}
