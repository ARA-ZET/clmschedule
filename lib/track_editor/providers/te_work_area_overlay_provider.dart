// track_editor/providers/te_work_area_overlay_provider.dart
//
// The work-areas overlay: every saved work area drawn on the track editor map,
// so a round's areas can be picked off the map instead of found by name in a
// list. Searching a list only works when you already know what an area is
// called; looking at the map is how you actually know which ground a round
// covered.
//
// Areas are fetched once per session on first show — the catalogue is small,
// it does not change while a round is being processed, and re-reading it on
// every toggle would put a Firestore round trip in front of a button press.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/work_area.dart';
import '../../providers/schedule_provider.dart';

final teWorkAreaOverlayRiverpod =
    riverpod.ChangeNotifierProvider<TEWorkAreaOverlayProvider>(
  (ref) => TEWorkAreaOverlayProvider(),
);

class TEWorkAreaOverlayProvider extends ChangeNotifier {
  bool _visible = false;
  List<WorkArea> _areas = const [];
  bool _loading = false;
  String? _error;

  /// Whether the overlay is drawn on the map.
  bool get isVisible => _visible;

  /// Every saved work area, once loaded.
  List<WorkArea> get areas => _areas;

  bool get isLoading => _loading;
  String? get error => _error;

  /// True once a fetch has completed, successfully or not — so a genuinely
  /// empty catalogue does not look like a load that never happened.
  bool get hasLoaded => _loaded;
  bool _loaded = false;

  /// Show or hide the overlay, fetching the catalogue the first time it is
  /// shown.
  Future<void> toggle(ScheduleProvider schedule) async {
    _visible = !_visible;
    notifyListeners();
    if (_visible) await ensureLoaded(schedule);
  }

  void hide() {
    if (!_visible) return;
    _visible = false;
    notifyListeners();
  }

  /// Fetch the work areas unless they are already in hand.
  Future<void> ensureLoaded(ScheduleProvider schedule) async {
    if (_loading || _loaded) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final areas = await schedule.fetchWorkAreas();
      _areas = areas.where((a) => a.polygonPoints.length >= 3).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      _loaded = true;
    } catch (e) {
      _error = 'Could not load work areas: $e';
      debugPrint('[TEWorkAreaOverlay] load failed: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Re-fetch, for when an area has been added or renamed elsewhere.
  Future<void> refresh(ScheduleProvider schedule) async {
    _loaded = false;
    await ensureLoaded(schedule);
  }
}
