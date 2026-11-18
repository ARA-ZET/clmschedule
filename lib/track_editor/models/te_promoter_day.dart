// track_editor/models/te_promoter_day.dart
//
// One distributor's one working day, assembled from every matched GPX pair
// in a Report-mode folder scan that resolved to that (distributor, date).
// Two rounds by the same distributor on the same day merge into one
// TEPromoterDay — "a promoter day is a promoter's working day", not a file.
import 'dart:typed_data';

import 'package:gpx/gpx.dart';

import '../../models/distributor.dart';
import '../utils/te_track_analysis.dart';

/// A proof-of-handout photo attached to a report date — every promoter who
/// worked that day shares the same set.
///
/// [bytes] is always present (needed to embed the image in the PDF without
/// a re-download); [url] is filled in once the photo has been uploaded to
/// Cloud Storage alongside that date's GPX files.
///
/// A photo found in the scanned folder carries its [storagePath], and
/// [takenAt] when its file name or camera data says when it was taken.
class TEProofPhoto {
  final Uint8List bytes;
  final String fileName;
  final String? url;
  final String? storagePath;
  final DateTime? takenAt;

  const TEProofPhoto({
    required this.bytes,
    required this.fileName,
    this.url,
    this.storagePath,
    this.takenAt,
  });

  TEProofPhoto copyWith({String? url, String? storagePath}) => TEProofPhoto(
        bytes: bytes,
        fileName: fileName,
        url: url ?? this.url,
        storagePath: storagePath ?? this.storagePath,
        takenAt: takenAt,
      );
}

class TEPromoterDay {
  final Distributor distributor;
  final DateTime date;

  /// Every track/waypoint file that contributed to this day, merged.
  final List<Trk> tracks;
  final List<Wpt> waypoints;

  /// Cloud Storage paths of every source file that fed this day — kept so
  /// proof photos can be uploaded alongside them and so the picker can show
  /// the user exactly which files were found.
  final List<String> sourcePaths;

  TEPromoterDay({
    required this.distributor,
    required this.date,
    required this.tracks,
    required this.waypoints,
    required this.sourcePaths,
  });

  /// Stable identity for this promoter day — used as the selection-set key
  /// in the report provider and to decide whether two matched pairs merge.
  String get key => '${distributor.id}|${date.year}-${date.month}-${date.day}';

  /// Computed once, on first access, and cached — a full shift's worth of
  /// trackpoints is not cheap to re-derive on every rebuild.
  TETrackAnalysis? _analysis;
  TETrackAnalysis get analysis =>
      _analysis ??= TETrackAnalysis.from(tracks: tracks, waypoints: waypoints);
}
