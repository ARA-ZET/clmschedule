// track_editor/providers/te_letterbox_write_provider.dart
//
// Writing a round's waypoints back into the curated letterbox index.
//
// The other direction of `TELetterboxCheckProvider`: that one asks the index
// how many letterboxes are inside a work area, this one makes the index say
// what a freshly walked round found there. Both sit on the shared letterbox
// primitives — `LetterboxCountService` for reading, `LetterboxAreaWriteService`
// for writing — so the track editor never grows its own idea of what the
// index contains.
//
// Two-step by design. [preview] loads and computes the whole change without
// writing a byte, so the operator confirms an exact number of letterboxes
// removed and added per suburb; [apply] then writes precisely what was shown.
// Replacing part of the dataset the business quotes from is not something to
// do on a single unlabelled click.
//
// A successful write also files the polygon in the **Client Maps** library
// with the count and the houses-versus-apartments split now under it. That
// number is re-counted from the index after the write rather than taken from
// the waypoints, so a client area says exactly what the map editor, a quote
// and a distributor review would each say for the same shape. The undo rolls
// the client area back with it — a quote must never be left reading a count
// that has been withdrawn.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';

import '../../letterbox/services/letterbox_area_write_service.dart';
import '../../letterbox/services/letterbox_count_service.dart';
import '../../letterbox/utils/letterbox_split.dart';
import '../../services/client_area_service.dart';
import 'te_letterbox_check_provider.dart';

final teLetterboxWriteRiverpod =
    riverpod.ChangeNotifierProvider<TELetterboxWriteProvider>((ref) {
  // Deliberately the comparison panel's own count cache: an update must
  // invalidate the payloads the panel scores rounds against, or the next
  // recheck compares the round to the numbers it just overwrote. The same
  // instance does the post-write recount, so the client area's number is read
  // from the payload the write just produced.
  final counter = ref.read(teLetterboxCheckRiverpod).countService;
  return TELetterboxWriteProvider(
    service: LetterboxAreaWriteService(counter: counter),
    counter: counter,
  );
});

class TELetterboxWriteProvider extends ChangeNotifier {
  TELetterboxWriteProvider({
    LetterboxAreaWriteService? service,
    LetterboxCountService? counter,
    ClientAreaService? clientAreas,
  })  : _service = service ?? LetterboxAreaWriteService(),
        _counter = counter ?? LetterboxCountService(),
        _clientAreas = clientAreas ?? ClientAreaService();

  final LetterboxAreaWriteService _service;
  final LetterboxCountService _counter;
  final ClientAreaService _clientAreas;

  bool _busy = false;
  String? _progress;
  String? _error;
  LetterboxAreaPlan? _plan;
  LetterboxAreaWriteResult? _result;

  /// The last write's undo record and the area it covered, kept for the
  /// session so a replacement can be walked back from the map.
  LetterboxAreaUndo? _undo;
  String? _undoAreaName;

  /// The Client Maps entry the last write produced, and whether it created or
  /// refreshed one. Held alongside the undo record so both roll back together.
  ClientAreaUpsert? _clientUpsert;

  bool get isBusy => _busy;

  /// What the provider is currently doing, for a progress line.
  String? get progress => _progress;

  String? get error => _error;

  /// The pending change, once [preview] has worked it out.
  LetterboxAreaPlan? get plan => _plan;

  /// The last completed write, or null if none has finished in this session.
  LetterboxAreaWriteResult? get result => _result;

  bool get canUndo => _undo != null;

  /// Name of the work area the undoable write covered.
  String? get undoAreaName => _undoAreaName;

  /// Suburbs the pending undo would restore.
  int get undoSuburbCount => _undo?.suburbCount ?? 0;

  /// Suburb ids the pending undo would rewrite. Read from the undo record
  /// rather than from [result], which a later preview clears.
  List<String> get undoSuburbIds => _undo?.suburbIds ?? const [];

  /// The Client Maps entry the last write filed, or null when it filed none.
  ClientAreaUpsert? get clientArea => _clientUpsert;

  /// Waypoints from [waypoints] that carry a usable position.
  ///
  /// A GPX waypoint with no lat/lon is not a drop that happened somewhere
  /// unknown — it is an unusable record, and treating it as one more letterbox
  /// would put a point in the Gulf of Guinea. Exact (0, 0) is dropped too, not
  /// just null: `Wpt` defaults both coordinates to 0.0, so a `<wpt>` element
  /// missing its attributes parses as null island rather than as null.
  static List<LatLng> positionsOf(List<Wpt> waypoints) {
    final out = <LatLng>[];
    for (final w in waypoints) {
      final lat = w.lat, lon = w.lon;
      if (lat == null || lon == null) continue;
      if (lat == 0.0 && lon == 0.0) continue;
      out.add(LatLng(lat, lon));
    }
    return out;
  }

  /// Work out what replacing the letterboxes inside [area] with [fresh] would
  /// do. Writes nothing.
  Future<LetterboxAreaPlan?> preview({
    required List<LatLng> area,
    required List<LatLng> fresh,
  }) async {
    if (_busy) return null;
    _busy = true;
    _error = null;
    _plan = null;
    _result = null;
    _progress = 'Reading the letterbox index…';
    notifyListeners();

    try {
      _plan = await _service.plan(
        area: area,
        fresh: fresh,
        onProgress: (done, total, name) {
          _progress = 'Reading $done of $total: $name…';
          notifyListeners();
        },
      );
    } catch (e) {
      _error = 'Could not read the letterbox index: $e';
      debugPrint('[TELetterboxWrite] preview failed: $e');
    } finally {
      _busy = false;
      _progress = null;
      notifyListeners();
    }
    return _plan;
  }

  /// Write the previewed change, and file the polygon in Client Maps.
  ///
  /// Returns true when at least one suburb was updated. A failure to file the
  /// client area does NOT make this false: the index write is the operation
  /// that matters and it has already succeeded — the client-library step is
  /// reported through [error] instead, so it cannot be mistaken for the write
  /// having been rolled back.
  Future<bool> apply({
    required String areaName,
    String client = '',
    String? sourcePolygonId,
    bool addToClientMaps = true,
  }) async {
    final plan = _plan;
    if (_busy || plan == null || !plan.hasChanges) return false;

    _busy = true;
    _error = null;
    _clientUpsert = null;
    _progress = 'Updating the letterbox index…';
    notifyListeners();

    var wrote = false;
    try {
      final result = await _service.apply(
        plan,
        onProgress: (done, total, name) {
          _progress = 'Updating $done of $total: $name…';
          notifyListeners();
        },
      );
      _result = result;
      wrote = result.succeeded.isNotEmpty;
      if (result.undo != null) {
        _undo = result.undo;
        _undoAreaName = areaName;
      }
      if (result.failures.isNotEmpty) {
        _error = 'Could not update '
            '${result.failures.map((o) => o.suburbName).join(', ')}.';
      }

      if (wrote && addToClientMaps) {
        _progress = 'Filing $areaName in Client Maps…';
        notifyListeners();
        await _fileInClientMaps(
          area: plan.area,
          areaName: areaName,
          client: client,
          sourcePolygonId: sourcePolygonId,
        );
      }
    } catch (e) {
      _error = 'Could not update the letterbox index: $e';
      debugPrint('[TELetterboxWrite] apply failed: $e');
    } finally {
      _busy = false;
      _progress = null;
      notifyListeners();
    }
    return wrote;
  }

  /// Count the polygon against the index the write just produced, and put the
  /// result in the Client Maps library.
  ///
  /// The recount is the point. Taking the number straight from the waypoints
  /// would quietly disagree with the map editor and every quote for the same
  /// shape — waypoints that landed outside every suburb boundary were never
  /// stored, and the count has to reflect what the index actually holds.
  Future<void> _fileInClientMaps({
    required List<LatLng> area,
    required String areaName,
    required String client,
    String? sourcePolygonId,
  }) async {
    try {
      final counted = await _counter.countIn(area);
      _clientUpsert = await _clientAreas.upsertFromSurvey(
        name: areaName,
        points: area,
        letterBoxEstimate: counted.count,
        letterBoxSplit: counted.breakdown.toLetterBoxSplit(),
        client: client,
        sourcePolygonId: sourcePolygonId,
      );
    } catch (e) {
      debugPrint('[TELetterboxWrite] Client Maps write failed: $e');
      _error = 'The letterbox index was updated, but this area could not be '
          'saved to Client Maps: $e';
    }
  }

  /// Put the last write back. Available only for this session — a reload
  /// loses it, which the UI says.
  Future<bool> undoLastWrite() async {
    final undo = _undo;
    if (_busy || undo == null) return false;

    _busy = true;
    _error = null;
    _progress = 'Restoring ${undo.suburbCount} suburb(s)…';
    notifyListeners();

    var restored = false;
    try {
      final result = await _service.restore(
        undo,
        onProgress: (done, total, name) {
          _progress = 'Restoring $done of $total: $name…';
          notifyListeners();
        },
      );
      restored = result.failures.isEmpty;
      if (!restored) {
        _error = 'Could not restore '
            '${result.failures.map((o) => o.suburbName).join(', ')}.';
      }

      // Roll the client area back with the index it was counted from — an
      // area left quoting a number that has just been withdrawn is worse than
      // no area at all.
      final upsert = _clientUpsert;
      if (upsert != null) {
        try {
          await _clientAreas.revertUpsert(upsert);
        } catch (e) {
          debugPrint('[TELetterboxWrite] Client Maps revert failed: $e');
          _error = 'The letterbox index was restored, but '
              '"${upsert.saved.name}" in Client Maps still holds the '
              'surveyed numbers: $e';
        }
      }

      // Cleared either way: a partial restore must not invite a second one,
      // which would write the same stale points over whatever survived.
      _undo = null;
      _undoAreaName = null;
      _clientUpsert = null;
      _result = null;
    } catch (e) {
      _error = 'Could not restore: $e';
      debugPrint('[TELetterboxWrite] undo failed: $e');
    } finally {
      _busy = false;
      _progress = null;
      notifyListeners();
    }
    return restored;
  }

  /// Drop the pending preview — the dialog was dismissed without writing.
  void clearPlan() {
    if (_plan == null && _error == null && _result == null) return;
    _plan = null;
    _error = null;
    _result = null;
    notifyListeners();
  }
}
