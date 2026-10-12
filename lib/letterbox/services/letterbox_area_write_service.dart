// letterbox/services/letterbox_area_write_service.dart
//
// Writing back to the letterbox index inside a drawn area.
//
// The counterpart to `LetterboxCountService`: that one answers "how many
// letterboxes are inside this polygon", this one answers "make the
// letterboxes inside this polygon be these instead". Every caller that
// replaces part of the index goes through here — the curation page's
// replace-from-folders and replace-from-files tools, and the track editor's
// update-from-waypoints action — so the rules below hold wherever the
// replacement is triggered from, rather than being reimplemented per screen.
//
// The rules, in one place:
//
//  * **A letterbox belongs to the suburb that geographically contains it.**
//    A drawn polygon rarely respects suburb boundaries, so the work is split
//    per suburb: each keeps its points outside the polygon and gains only the
//    fresh points inside BOTH the polygon and its own boundary. Draw sloppily
//    over a neighbour and its points still go to it.
//  * **Nothing is written before the whole change is known.** [plan] loads and
//    computes; [apply] writes. The caller can show the operator exactly what
//    will change, and what is written is what was shown — not a re-read that
//    may have moved underneath the confirmation.
//  * **Status is left alone.** A replace is a deliberate human action, so a
//    verified suburb stays verified. [LetterboxAreaPlan.verifiedAffected]
//    names them so the confirmation can say which trusted suburbs are about
//    to change.
//  * **Every write is undoable within the session.** [apply] returns a
//    [LetterboxAreaUndo] holding each touched suburb's previous point set and
//    metadata; [restore] puts them back.
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/work_suburb.dart';
import '../../shareable_maps/services/suburb_data_service.dart';
import '../../track_editor/services/point_in_polygon.dart';
import '../models/letterbox_suburb.dart';
import 'letterbox_codec.dart';
import 'letterbox_count_service.dart';
import 'letterbox_firestore_service.dart';
import 'letterbox_storage_service.dart';

/// What a replacement will do to one suburb, worked out before any write.
class LetterboxAreaSuburbPlan {
  final String suburbId;
  final String suburbName;

  /// The suburb's whole point set as it stands, kept so [apply] writes exactly
  /// what was previewed and so the undo record needs no extra download.
  final List<LatLng> existing;

  /// What survives: the points outside the drawn area.
  final List<LatLng> kept;

  /// What arrives: fresh points inside both the area and this suburb.
  final List<LatLng> incoming;

  /// This suburb's metadata before the write, or null when it has none yet.
  final LetterboxSuburb? meta;

  /// The suburb's payload could not be read. Reported rather than treated as
  /// an empty suburb — replacing on the strength of a failed load would
  /// silently delete everything it holds.
  final bool loadFailed;

  const LetterboxAreaSuburbPlan({
    required this.suburbId,
    required this.suburbName,
    required this.existing,
    required this.kept,
    required this.incoming,
    this.meta,
    this.loadFailed = false,
  });

  /// Letterboxes this suburb loses.
  int get removeCount => existing.length - kept.length;

  /// Letterboxes this suburb gains.
  int get addCount => incoming.length;

  /// The point set that will be written.
  List<LatLng> get result => [...kept, ...incoming];

  /// Whether this suburb is actually touched. A suburb can overlap the area's
  /// bounding box and still have nothing inside the area itself.
  bool get changes => !loadFailed && (removeCount > 0 || incoming.isNotEmpty);

  bool get wasVerified => meta?.status == LetterboxSuburbStatus.verified;
}

/// The full change a replacement will make, across every suburb the area
/// touches. Nothing here has been written yet.
class LetterboxAreaPlan {
  final List<LatLng> area;
  final List<LetterboxAreaSuburbPlan> suburbs;

  /// Fresh points inside the drawn area that fall inside no suburb boundary
  /// at all, and so have nowhere to be stored.
  ///
  /// Surfaced rather than dropped quietly: suburb boundaries run down the
  /// middle of the road and do not tile the city perfectly, so a handful of
  /// drops in a gap is normal — a large number means the area reaches over
  /// ground the suburb layer does not cover, and the operator should see that
  /// before agreeing to the write.
  final int unplacedFresh;

  const LetterboxAreaPlan({
    required this.area,
    required this.suburbs,
    this.unplacedFresh = 0,
  });

  static const empty = LetterboxAreaPlan(area: [], suburbs: []);

  /// Only the suburbs that actually change.
  List<LetterboxAreaSuburbPlan> get affected =>
      suburbs.where((s) => s.changes).toList(growable: false);

  /// Suburbs whose payload could not be read; they are left untouched.
  List<LetterboxAreaSuburbPlan> get unreadable =>
      suburbs.where((s) => s.loadFailed).toList(growable: false);

  /// Affected suburbs that are curated and signed off. The write keeps them
  /// verified, so a confirmation should name them.
  List<LetterboxAreaSuburbPlan> get verifiedAffected =>
      affected.where((s) => s.wasVerified).toList(growable: false);

  int get totalRemoved => affected.fold(0, (sum, s) => sum + s.removeCount);
  int get totalAdded => affected.fold(0, (sum, s) => sum + s.addCount);

  bool get hasChanges => affected.isNotEmpty;
}

/// What a replacement did to one suburb.
class LetterboxAreaOutcome {
  final String suburbId;
  final String suburbName;
  final int removed;
  final int added;
  final bool wasVerified;
  final bool failed;

  const LetterboxAreaOutcome({
    required this.suburbId,
    required this.suburbName,
    required this.removed,
    required this.added,
    this.wasVerified = false,
    this.failed = false,
  });
}

/// One suburb's state before a write, so it can be put back.
class _SuburbSnapshot {
  final String suburbId;
  final String suburbName;
  final List<LatLng> points;
  final LetterboxSuburb? meta;

  const _SuburbSnapshot({
    required this.suburbId,
    required this.suburbName,
    required this.points,
    required this.meta,
  });
}

/// Everything needed to undo one replacement, for as long as the session
/// lives. Held in memory only — a page reload loses it, which the UI says.
class LetterboxAreaUndo {
  final DateTime at;
  final List<_SuburbSnapshot> _snapshots;

  LetterboxAreaUndo._(this.at, this._snapshots);

  int get suburbCount => _snapshots.length;

  List<String> get suburbNames =>
      _snapshots.map((s) => s.suburbName).toList(growable: false);

  /// The suburbs this undo would rewrite, for invalidating count caches.
  List<String> get suburbIds =>
      _snapshots.map((s) => s.suburbId).toList(growable: false);

  /// Letterboxes across every touched suburb as they were before the write.
  int get totalPoints => _snapshots.fold(0, (sum, s) => sum + s.points.length);
}

/// The result of applying a plan.
class LetterboxAreaWriteResult {
  final List<LetterboxAreaOutcome> outcomes;

  /// Metadata as written, keyed by suburb id, so a caller holding a metadata
  /// cache can update it without re-reading Firestore.
  final Map<String, LetterboxSuburb> updatedMeta;

  /// Null when nothing was written.
  final LetterboxAreaUndo? undo;

  const LetterboxAreaWriteResult({
    required this.outcomes,
    this.updatedMeta = const {},
    this.undo,
  });

  static const empty = LetterboxAreaWriteResult(outcomes: []);

  List<LetterboxAreaOutcome> get succeeded =>
      outcomes.where((o) => !o.failed).toList(growable: false);

  List<LetterboxAreaOutcome> get failures =>
      outcomes.where((o) => o.failed).toList(growable: false);

  int get totalRemoved => succeeded.fold(0, (sum, o) => sum + o.removed);
  int get totalAdded => succeeded.fold(0, (sum, o) => sum + o.added);

  /// Suburbs whose stored payload changed, for invalidating count caches.
  List<String> get touchedSuburbIds =>
      succeeded.map((o) => o.suburbId).toList(growable: false);

  /// One line saying what happened, worded the same wherever a replacement is
  /// triggered from.
  String get summary {
    if (outcomes.isEmpty) return 'Nothing inside that area changed.';
    final done = succeeded;
    final failed = failures;
    if (done.isEmpty) {
      return 'Nothing was written. Failed: '
          '${failed.map((o) => o.suburbName).join(', ')}.';
    }
    return 'Replaced across ${done.length} suburb(s): '
        'removed $totalRemoved, added $totalAdded — '
        '${done.map((o) => '${o.suburbName} (+${o.added}/-${o.removed})').join(', ')}.'
        '${failed.isEmpty ? '' : ' Failed: ${failed.map((o) => o.suburbName).join(', ')}.'}';
  }
}

/// Replaces the letterbox index inside a drawn area, across every suburb the
/// area reaches into.
class LetterboxAreaWriteService {
  final SuburbDataService _suburbData;
  final LetterboxFirestoreService _firestore;
  final LetterboxStorageService _storage;

  /// Count cache to invalidate after a write, so the next count reflects what
  /// was just written instead of the session's stale payload.
  final LetterboxCountService? _counter;

  LetterboxAreaWriteService({
    SuburbDataService? suburbData,
    LetterboxFirestoreService? firestore,
    LetterboxStorageService? storage,
    LetterboxCountService? counter,
  })  : _suburbData = suburbData ?? SuburbDataService(),
        _firestore = firestore ?? LetterboxFirestoreService(),
        _storage = storage ?? LetterboxStorageService(),
        _counter = counter;

  /// Suburb boundaries, session-cached by [SuburbDataService]. Degenerate
  /// entries are dropped — a suburb with fewer than three vertices can neither
  /// contain a point nor be tested against one.
  Future<List<WorkSuburb>> catalogue() async {
    final all = await _suburbData.loadSuburbs();
    return all
        .where((s) => s.polygonPoints.length >= 3)
        .toList(growable: false);
  }

  /// Suburbs whose boundary could hold part of [area].
  ///
  /// Bounds test only — cheap, and a false positive costs nothing because the
  /// per-suburb pass finds no points to change and skips the write.
  Future<List<WorkSuburb>> suburbsOverlapping(List<LatLng> area) async {
    final box = LetterboxBounds.fromPoints(area);
    if (box == null) return const [];
    return (await catalogue()).where((s) {
      final b = LetterboxBounds.fromPoints(s.polygonPoints);
      return b != null && b.intersects(box);
    }).toList(growable: false);
  }

  /// Work out what replacing the contents of [area] with [fresh] would do,
  /// without writing anything.
  ///
  /// [existingOverrides] lets a caller that already holds a suburb's points in
  /// memory — the curation page, for the suburb open on screen — declare them
  /// the authority, so an unsaved edit is not overwritten by the stored copy.
  ///
  /// [knownMeta] avoids a metadata read for suburbs the caller has already
  /// loaded; anything missing is fetched.
  Future<LetterboxAreaPlan> plan({
    required List<LatLng> area,
    required List<LatLng> fresh,
    Map<String, List<LatLng>> existingOverrides = const {},
    Map<String, LetterboxSuburb> knownMeta = const {},
    void Function(int done, int total, String suburbName)? onProgress,
  }) async {
    if (area.length < 3) return LetterboxAreaPlan.empty;

    final candidates = await suburbsOverlapping(area);
    if (candidates.isEmpty) {
      return LetterboxAreaPlan(area: area, suburbs: const []);
    }

    // Only the fresh points inside the area are in play at all; the caller may
    // hand us a whole round's waypoints and expect the polygon to do the
    // clipping.
    final freshInArea = fresh
        .where((p) => isPointInPolygon(p, area))
        .toList(growable: false);

    final plans = <LetterboxAreaSuburbPlan>[];
    final placed = <int>{};

    for (var i = 0; i < candidates.length; i++) {
      final suburb = candidates[i];
      onProgress?.call(i + 1, candidates.length, suburb.name);

      List<LatLng> existing;
      var loadFailed = false;
      final override = existingOverrides[suburb.id];
      if (override != null) {
        existing = List<LatLng>.from(override);
      } else {
        try {
          final bytes = await _storage.load(suburb.id);
          existing = bytes == null
              ? <LatLng>[]
              : await LetterboxCodec.decodeAsync(bytes);
        } catch (e) {
          debugPrint('[LetterboxAreaWrite] ${suburb.name} load failed: $e');
          existing = const [];
          loadFailed = true;
        }
      }

      final kept = loadFailed
          ? existing
          : existing
              .where((p) => !isPointInPolygon(p, area))
              .toList(growable: false);

      final incoming = <LatLng>[];
      if (!loadFailed) {
        for (var f = 0; f < freshInArea.length; f++) {
          if (isPointInPolygon(freshInArea[f], suburb.polygonPoints)) {
            incoming.add(freshInArea[f]);
            placed.add(f);
          }
        }
      } else {
        // Still record which fresh points this suburb would have taken, so an
        // unreadable suburb does not also show up as a coverage gap.
        for (var f = 0; f < freshInArea.length; f++) {
          if (isPointInPolygon(freshInArea[f], suburb.polygonPoints)) {
            placed.add(f);
          }
        }
      }

      plans.add(LetterboxAreaSuburbPlan(
        suburbId: suburb.id,
        suburbName: suburb.name,
        existing: existing,
        kept: kept,
        incoming: incoming,
        meta: await _metaFor(suburb.id, knownMeta),
        loadFailed: loadFailed,
      ));
    }

    return LetterboxAreaPlan(
      area: area,
      suburbs: plans,
      unplacedFresh: freshInArea.length - placed.length,
    );
  }

  /// Write [plan]. Only the suburbs it marks as changing are touched.
  Future<LetterboxAreaWriteResult> apply(
    LetterboxAreaPlan plan, {
    void Function(int done, int total, String suburbName)? onProgress,
  }) async {
    final affected = plan.affected;
    if (affected.isEmpty) return LetterboxAreaWriteResult.empty;

    final outcomes = <LetterboxAreaOutcome>[];
    final updatedMeta = <String, LetterboxSuburb>{};
    final snapshots = <_SuburbSnapshot>[];

    for (var i = 0; i < affected.length; i++) {
      final suburb = affected[i];
      onProgress?.call(i + 1, affected.length, suburb.suburbName);

      final next = suburb.result;
      try {
        final written = await _write(
          suburbId: suburb.suburbId,
          suburbName: suburb.suburbName,
          points: next,
          previous: suburb.meta,
        );
        updatedMeta[suburb.suburbId] = written;
        snapshots.add(_SuburbSnapshot(
          suburbId: suburb.suburbId,
          suburbName: suburb.suburbName,
          points: suburb.existing,
          meta: suburb.meta,
        ));
        outcomes.add(LetterboxAreaOutcome(
          suburbId: suburb.suburbId,
          suburbName: suburb.suburbName,
          removed: suburb.removeCount,
          added: suburb.addCount,
          wasVerified: suburb.wasVerified,
        ));
      } catch (e) {
        debugPrint('[LetterboxAreaWrite] ${suburb.suburbName} save failed: $e');
        outcomes.add(LetterboxAreaOutcome(
          suburbId: suburb.suburbId,
          suburbName: suburb.suburbName,
          removed: 0,
          added: 0,
          failed: true,
        ));
      }
    }

    return LetterboxAreaWriteResult(
      outcomes: outcomes,
      updatedMeta: updatedMeta,
      undo: snapshots.isEmpty
          ? null
          : LetterboxAreaUndo._(DateTime.now(), snapshots),
    );
  }

  /// Put every suburb in [undo] back exactly as it was before the write that
  /// produced it.
  ///
  /// A suburb that had no index at all before — no points and no metadata
  /// document — is removed again rather than left behind as an empty one.
  Future<LetterboxAreaWriteResult> restore(
    LetterboxAreaUndo undo, {
    void Function(int done, int total, String suburbName)? onProgress,
  }) async {
    final outcomes = <LetterboxAreaOutcome>[];
    final updatedMeta = <String, LetterboxSuburb>{};

    for (var i = 0; i < undo._snapshots.length; i++) {
      final snap = undo._snapshots[i];
      onProgress?.call(i + 1, undo._snapshots.length, snap.suburbName);

      try {
        if (snap.points.isEmpty && snap.meta == null) {
          await _storage.delete(snap.suburbId);
          await _firestore.delete(snap.suburbId);
          _counter?.invalidate(snap.suburbId);
        } else {
          updatedMeta[snap.suburbId] = await _write(
            suburbId: snap.suburbId,
            suburbName: snap.suburbName,
            points: snap.points,
            previous: snap.meta,
            // The pre-write document is the truth here, not a derivation from
            // it: restoring must not leave a suburb looking freshly edited.
            restoreExactly: snap.meta,
          );
        }
        outcomes.add(LetterboxAreaOutcome(
          suburbId: snap.suburbId,
          suburbName: snap.suburbName,
          removed: 0,
          added: snap.points.length,
        ));
      } catch (e) {
        debugPrint('[LetterboxAreaWrite] restore ${snap.suburbName} failed: $e');
        outcomes.add(LetterboxAreaOutcome(
          suburbId: snap.suburbId,
          suburbName: snap.suburbName,
          removed: 0,
          added: 0,
          failed: true,
        ));
      }
    }

    return LetterboxAreaWriteResult(
        outcomes: outcomes, updatedMeta: updatedMeta);
  }

  // ── Internals ────────────────────────────────────────────────────────

  Future<LetterboxSuburb?> _metaFor(
      String suburbId, Map<String, LetterboxSuburb> known) async {
    if (known.containsKey(suburbId)) return known[suburbId];
    try {
      return await _firestore.get(suburbId);
    } catch (e) {
      debugPrint('[LetterboxAreaWrite] meta read $suburbId failed: $e');
      return null;
    }
  }

  /// Encode, upload, then write the metadata document. Storage first: a
  /// metadata document that promises a payload which was never written is
  /// worse than a payload nothing points at yet.
  Future<LetterboxSuburb> _write({
    required String suburbId,
    required String suburbName,
    required List<LatLng> points,
    required LetterboxSuburb? previous,
    LetterboxSuburb? restoreExactly,
  }) async {
    final bytes = LetterboxCodec.encode(
      suburbId: suburbId,
      suburbName: suburbName,
      points: points,
    );
    final size = await _storage.save(suburbId, bytes);

    final updated = LetterboxSuburb(
      suburbId: suburbId,
      suburbName: suburbName,
      count: points.length,
      // Status is left alone: this is a curator acting deliberately, so a
      // verified suburb stays verified. The plan names which verified suburbs
      // are affected so the confirmation can say so.
      status: restoreExactly?.status ??
          previous?.status ??
          LetterboxSuburbStatus.inProgress,
      seededCount: restoreExactly?.seededCount ??
          previous?.seededCount ??
          points.length,
      hasNewCandidates: restoreExactly?.hasNewCandidates ?? false,
      verifiedAt: previous?.verifiedAt,
      verifiedBy: previous?.verifiedBy,
      storagePath: LetterboxStorageService.pathFor(suburbId),
      storageBytes: size,
      bounds: LetterboxBounds.fromPoints(points),
      formatVersion: LetterboxCodec.formatVersion,
    );
    await _firestore.save(updated);
    _counter?.invalidate(suburbId);
    return updated;
  }
}
