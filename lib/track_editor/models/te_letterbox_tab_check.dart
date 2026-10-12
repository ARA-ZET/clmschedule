// track_editor/models/te_letterbox_tab_check.dart
//
// A tab's own dropped-versus-expected comparison, kept on the tab so switching
// away and back shows the numbers straight away instead of recounting them.
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../letterbox/services/letterbox_count_service.dart';
import 'styled_polygon.dart';

/// One polygon's dropped-versus-expected comparison.
class TELetterboxComparison {
  /// Waypoints the distributor recorded inside this polygon.
  final int dropped;

  /// Curated letterboxes inside the same polygon.
  final LetterboxCount expected;

  const TELetterboxComparison({required this.dropped, required this.expected});

  int get expectedCount => expected.count;

  /// Dropped as a fraction of expected. Null when there is nothing to compare
  /// against — an area with no curated letterboxes yields no meaningful
  /// percentage, and reporting 0% there would read as a failed round.
  double? get coverage => expected.count == 0 ? null : dropped / expected.count;

  /// Letterboxes in this area that went undelivered.
  int get shortfall => expected.count > dropped ? expected.count - dropped : 0;

  /// Drops beyond the number of letterboxes that exist here. Either the same
  /// boxes were hit twice or the waypoints are not genuine — worth flagging
  /// distinctly from a simple shortfall.
  int get overDelivery =>
      dropped > expected.count ? dropped - expected.count : 0;

  /// Whether every suburb feeding this number has been curated and signed
  /// off. An unverified expected count is not evidence of anything.
  bool get isTrusted => expected.isTrusted;
}

/// Identifies a work area by what it is — its name and boundary — rather than
/// by object identity. Grouping runs through `compute`, which copies its
/// result on native platforms, so the polygons a panel shows are not always
/// the very objects that were counted. Two areas sharing a name still get
/// separate keys unless they also share a boundary, in which case they are the
/// same ground and the same number.
int teAreaKey(String name, List<LatLng> points) =>
    Object.hash(name, Object.hashAll(points));

/// The comparison state of one tab. Mutated only by
/// `TELetterboxCheckProvider`, which notifies when it changes.
class TELetterboxTabCheck {
  /// The polygons last counted, with their waypoints grouped. For a trimmed
  /// tab this is its own grouping; otherwise it was grouped for the check
  /// alone, without touching the tab.
  List<TETargetPolygon> polygons = const [];

  final Map<int, TELetterboxComparison> _results = {};
  LetterboxUnionResult? union;
  String? error;
  bool isChecking = false;

  /// Fingerprint of the inputs the stored results were counted from. When the
  /// tab's current fingerprint differs, the results are stale and a recheck
  /// is due — they stay on screen until it lands.
  int? signature;

  bool get hasResults => _results.isNotEmpty;

  TELetterboxComparison? resultFor(TETargetPolygon polygon) =>
      _results[teAreaKey(polygon.name, polygon.points)];

  /// Keep a finished count. [counted] and [comparisons] are index-aligned;
  /// [polygons] is everything to show, including areas without a boundary
  /// that could not be counted.
  void store({
    required List<TETargetPolygon> polygons,
    required List<TETargetPolygon> counted,
    required List<TELetterboxComparison> comparisons,
    required LetterboxUnionResult? union,
    required int signature,
  }) {
    this.polygons = polygons;
    _results
      ..clear()
      ..addEntries([
        for (var i = 0; i < counted.length; i++)
          MapEntry(
              teAreaKey(counted[i].name, counted[i].points), comparisons[i]),
      ]);
    this.union = union;
    this.signature = signature;
    error = null;
  }

  void reset({String? error, int? signature}) {
    polygons = const [];
    _results.clear();
    union = null;
    this.error = error;
    this.signature = signature;
  }
}
