// track_editor/providers/te_letterbox_check_provider.dart
//
// Compares what a distributor actually dropped inside each work-area polygon
// against how many letterboxes are really there, per the curated letterbox
// index. This is the review side of the same primitive the client maps quote
// from — `LetterboxCountService.countIn` — so an area's expected number is
// always the one number, whichever screen is asking.
//
// Each tab keeps its own result ([TETabItem.letterboxCheck]), so switching
// tabs never recounts. The provider watches the tabs and, in the background,
// rechecks any processing/trim tab whose work areas or drops have changed
// since it was last counted — newly opened rounds, a saved polygon edit, an
// undo, a schedule refresh, or a letterbox index update.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../letterbox/services/letterbox_count_service.dart';
import '../models/styled_polygon.dart';
import '../models/tab_item.dart';
import '../models/te_letterbox_tab_check.dart';
import '../services/point_in_polygon.dart';
import 'te_mode_provider.dart';
import 'te_tabs_provider.dart';

export '../models/te_letterbox_tab_check.dart'
    show TELetterboxComparison, TELetterboxTabCheck;

final teLetterboxCheckRiverpod =
    riverpod.ChangeNotifierProvider<TELetterboxCheckProvider>((ref) {
  final check = TELetterboxCheckProvider();
  // Fetch the suburb list while the user is still picking files, so the
  // first comparison does not start by waiting for it.
  check.countService.warmUp();
  ref.listen<TETabsProvider>(
    teTabsRiverpod,
    (_, tabs) => check.scheduleSweep(tabs),
    fireImmediately: true,
  );
  return check;
});

class TELetterboxCheckProvider extends ChangeNotifier {
  TELetterboxCheckProvider({LetterboxCountService? service})
      : _service = service ?? LetterboxCountService();

  final LetterboxCountService _service;

  /// The session's letterbox cache, shared with the update action so that
  /// writing back to the index invalidates the very payloads these
  /// comparisons are counted from — otherwise a recheck straight after an
  /// update would score the round against the numbers it just replaced.
  LetterboxCountService get countService => _service;

  /// Modes whose tabs are rechecked automatically. The others never show the
  /// comparison, so counting them would only spend letterbox reads.
  static const _autoModes = {TEMode.processing, TEMode.trim};

  /// Bumped whenever the letterbox index changes under us. Part of every
  /// tab's signature, so all stored results go stale at once.
  int _epoch = 0;

  TETabsProvider? _tabs;
  Timer? _debounce;
  bool _sweeping = false;
  bool _sweepAgain = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ── Reading ───────────────────────────────────────────────────────────────

  /// Whether [tab]'s stored numbers no longer match its data.
  bool isStale(TETabItem tab) =>
      tab.letterboxCheck.signature != _signatureOf(tab);

  /// Whether [tab] is being counted now or is waiting for the next sweep.
  bool isBusy(TETabItem tab) => tab.letterboxCheck.isChecking || isStale(tab);

  // ── Background sweep ──────────────────────────────────────────────────────

  /// Recheck stale tabs shortly after the tabs settle. Debounced so a burst
  /// of edits — a batch of opened tabs, a vertex drag — costs one sweep.
  void scheduleSweep(TETabsProvider tabs) {
    if (_disposed) return;
    _tabs = tabs;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _sweep);
  }

  Future<void> _sweep() async {
    if (_disposed) return;
    if (_sweeping) {
      _sweepAgain = true;
      return;
    }
    _sweeping = true;
    try {
      do {
        _sweepAgain = false;
        final tabs = _tabs;
        if (tabs == null || !_autoModes.contains(tabs.activeMode)) break;
        // The tab on screen first; the rest fill in behind it.
        final list = tabs.tabs.toList(growable: false);
        final cur = tabs.currentTab;
        final ordered = [
          if (cur >= 0 && cur < list.length) list[cur],
          for (var i = 0; i < list.length; i++)
            if (i != cur) list[i],
        ];
        final due = [
          for (final tab in ordered)
            if (!tab.letterboxCheck.isChecking && isStale(tab)) tab,
        ];
        // Start every due tab's downloads now, all at once: while the tab on
        // screen is counted, the others' suburbs are already arriving.
        if (due.length > 1) {
          unawaited(_service
              .prefetch([for (final tab in due) ..._shapesOf(tab)]).catchError(
                  (Object e) {
            debugPrint('[TELetterboxCheck] prefetch failed: $e');
          }));
        }
        for (final tab in due) {
          if (_disposed) return;
          if (!tab.letterboxCheck.isChecking && isStale(tab)) {
            await _checkTab(tab);
          }
          // Let a frame through between tabs so the editor stays responsive.
          await Future<void>.delayed(Duration.zero);
        }
      } while (_sweepAgain && !_disposed);
    } finally {
      _sweeping = false;
    }
  }

  // ── Checking ──────────────────────────────────────────────────────────────

  /// Count [tab] again now, even if its stored numbers look current.
  Future<void> recheck(TETabItem tab) async {
    if (tab.letterboxCheck.isChecking) return;
    await _checkTab(tab);
  }

  /// Count the curated letterboxes inside each of [tab]'s work areas and
  /// compare them against the waypoints dropped in each.
  ///
  /// An untrimmed tab is grouped here for the check alone — trimming is
  /// destructive, and reviewing a round must never alter the data being
  /// reviewed. Polygons that arrived without geometry are shown but not
  /// counted: "we could not check this" and "nothing was delivered here" must
  /// never look the same on a performance review.
  Future<void> _checkTab(TETabItem tab) async {
    final state = tab.letterboxCheck;
    final signature = _signatureOf(tab);

    List<TETargetPolygon> source;
    if (tab.polygons.isNotEmpty && tab.waypoints.isNotEmpty) {
      source = const [];
    } else {
      source = tab.targetPolygons;
      if (source.isEmpty) {
        // Nothing to compare yet. Record the signature so the sweep does not
        // keep coming back, and only notify if something was showing.
        final hadSomething = state.hasResults || state.error != null;
        state.reset(signature: signature);
        if (hadSomething) _notify();
        return;
      }
    }

    state.isChecking = true;
    _notify();
    try {
      if (source.isEmpty) {
        source = await groupWaypointsByPolygonAsync(
            List.of(tab.polygons), List.of(tab.waypoints));
      }
      final counted =
          source.where((p) => p.points.length >= 3).toList(growable: false);
      if (counted.isEmpty) {
        state.reset(
          signature: signature,
          error: 'These polygons carry no boundary — re-run the trim to '
              'compare them against the letterbox index.',
        );
        return;
      }

      final shapes = counted.map((p) => p.points).toList(growable: false);
      final counts = await _service.countInEach(shapes);
      final union = await _service.countUnion(shapes);
      state.store(
        polygons: source,
        counted: counted,
        comparisons: [
          for (var i = 0; i < counted.length; i++)
            TELetterboxComparison(
              dropped: counted[i].waypoints.length,
              expected: counts[i],
            ),
        ],
        union: union,
        signature: signature,
      );
    } catch (e) {
      // Keep the signature so a failing tab is not retried in a loop; the
      // Recheck button forces another go.
      state
        ..error = '$e'
        ..signature = signature;
      debugPrint('[TELetterboxCheck] comparison failed: $e');
    } finally {
      state.isChecking = false;
      _notify();
      // The tab may have changed while it was being counted (the signature
      // taken above is then already stale) — pick that up.
      final tabs = _tabs;
      if (tabs != null && isStale(tab)) scheduleSweep(tabs);
    }
  }

  /// The work-area boundaries [tab] will be counted over.
  static Iterable<List<LatLng>> _shapesOf(TETabItem tab) =>
      tab.polygons.isNotEmpty
          ? tab.polygons.map((p) => p.points)
          : tab.targetPolygons.map((p) => p.points);

  /// Fingerprint of everything a tab's comparison is counted from.
  int _signatureOf(TETabItem tab) {
    if (tab.polygons.isNotEmpty && tab.waypoints.isNotEmpty) {
      return Object.hash(
        _epoch,
        Object.hashAll(tab.polygons.map((p) => teAreaKey(p.name, p.points))),
        Object.hashAll(tab.waypoints.map((w) => Object.hash(w.lat, w.lon))),
      );
    }
    return Object.hash(
      _epoch,
      Object.hashAll(tab.targetPolygons.map(
          (p) => Object.hash(teAreaKey(p.name, p.points), p.waypoints.length))),
    );
  }

  // ── Invalidation ──────────────────────────────────────────────────────────

  /// Forget the cached letterbox payloads for [suburbIds] and mark every
  /// tab's result stale, so they are recounted against the updated index.
  /// Called after the index has been written to from the map.
  void invalidateSuburbs(Iterable<String> suburbIds) {
    for (final id in suburbIds) {
      _service.invalidate(id);
    }
    _epoch++;
    _notify();
    final tabs = _tabs;
    if (tabs != null) scheduleSweep(tabs);
  }
}
