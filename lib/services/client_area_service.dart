// services/client_area_service.dart
//
// CRUD over the Client Maps library: `clientAreas/{id}`.
//
// Mirrors the work-areas collection deliberately — same one-document-per-area
// shape, same cache-first one-shot read — so the two libraries behave the same
// in the map editor and neither becomes the odd one out. What is extra here is
// [upsertFromSurvey]: the path a polygon takes when a walked round has just
// replaced the letterbox index underneath it and the resulting count belongs
// in the client library.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/client_area.dart';
import '../recycle_bin/recycle_bin_entry.dart';
import '../recycle_bin/recycle_bin_writer.dart';
import '../models/custom_polygon.dart';

final clientAreaServiceRiverpod =
    riverpod.Provider<ClientAreaService>((ref) => ClientAreaService());

/// What an [ClientAreaService.upsertFromSurvey] did, and what it takes to put
/// it back.
///
/// [previous] is null when the survey created the area, in which case undoing
/// means deleting it; otherwise undoing means writing [previous] back exactly.
class ClientAreaUpsert {
  final ClientArea saved;
  final ClientArea? previous;

  const ClientAreaUpsert({required this.saved, this.previous});

  /// True when this survey put a new area into the library, rather than
  /// refreshing one that was already there.
  bool get wasCreated => previous == null;
}

class ClientAreaService {
  static const String collection = 'clientAreas';

  final FirebaseFirestore? _injectedDb;

  /// Resolved lazily rather than in the initializer list so that subclasses
  /// which override every method — test fakes, chiefly — never touch
  /// `FirebaseFirestore.instance` and so do not require an initialised app.
  FirebaseFirestore get _db => _injectedDb ?? FirebaseFirestore.instance;

  ClientAreaService({FirebaseFirestore? firestore}) : _injectedDb = firestore;

  CollectionReference<Map<String, dynamic>> get _col => _db.collection(collection);

  /// Every client area, live.
  Stream<List<ClientArea>> streamAll() => _col.snapshots().map((snap) =>
      snap.docs.map(ClientArea.fromFirestore).toList(growable: false));

  /// One-shot fetch. Tries the Firestore cache first to avoid a billed read,
  /// falling back to the server on a miss — the same pattern the work-areas
  /// collection uses for the map editor's load.
  Future<List<ClientArea>> fetchAllOnce() async {
    QuerySnapshot<Map<String, dynamic>> snap;
    try {
      snap = await _col.get(const GetOptions(source: Source.cache));
      if (snap.docs.isEmpty) snap = await _col.get();
    } catch (_) {
      snap = await _col.get();
    }
    return snap.docs.map(ClientArea.fromFirestore).toList(growable: false);
  }

  Future<ClientArea?> get(String id) async {
    if (id.isEmpty) return null;
    final doc = await _col.doc(id).get();
    return doc.exists ? ClientArea.fromFirestore(doc) : null;
  }

  /// Create an area and return its new id.
  Future<String> add(ClientArea area) async {
    final ref = await _col.add(area.toFirestore());
    return ref.id;
  }

  /// Overwrite an area. Uses set-with-merge rather than update so that
  /// restoring an area that was deleted in between still works.
  Future<void> save(ClientArea area) async {
    await _col.doc(area.id).set(area.toFirestore(), SetOptions(merge: true));
  }

  /// Moves the area to the Recycle Bin.
  Future<void> delete(String id) async {
    if (id.isEmpty) return;
    await RecycleBinWriter(_db).moveDocToBin(
      _col.doc(id),
      type: RecycleBinType.clientArea,
      label: (d) => '${(d['name'] as String?)?.trim().isNotEmpty == true ? (d['name'] as String).trim() : 'Unnamed'} (client area)',
    );
  }

  /// The area a re-survey of this polygon should refresh, if any.
  ///
  /// Matched on [sourcePolygonId] first, then on the name.
  ///
  /// **The name is the one that does the real work.** A track-editor polygon's
  /// id is derived from its name and geometry for schedule work maps, and from
  /// a timestamp for one drawn by hand — so nudging a vertex, or drawing the
  /// area again in a later session, produces a different id for the same
  /// ground. Without the name fallback, every such re-survey would file a
  /// second copy of the same area quoting a different number, and so would the
  /// first survey of an area someone had already drawn in the editor. The id
  /// match is kept as a fast path and as the thing that survives a rename.
  Future<ClientArea?> findForSurvey({
    String? sourcePolygonId,
    required String name,
  }) async {
    if (sourcePolygonId != null && sourcePolygonId.isNotEmpty) {
      try {
        final byPolygon = await _col
            .where('sourcePolygonId', isEqualTo: sourcePolygonId)
            .limit(1)
            .get();
        if (byPolygon.docs.isNotEmpty) {
          return ClientArea.fromFirestore(byPolygon.docs.first);
        }
      } catch (e) {
        debugPrint('[ClientArea] sourcePolygonId lookup failed: $e');
      }
    }

    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      final byName =
          await _col.where('name', isEqualTo: trimmed).limit(1).get();
      if (byName.docs.isNotEmpty) {
        return ClientArea.fromFirestore(byName.docs.first);
      }
    } catch (e) {
      debugPrint('[ClientArea] name lookup failed: $e');
    }
    return null;
  }

  /// Put a freshly surveyed polygon into the Client Maps library.
  ///
  /// The estimate and split passed here should be counted from the curated
  /// index *after* the survey has been written to it, not from the raw
  /// waypoints — so the number in the client library is the same number every
  /// other screen would report for that shape.
  ///
  /// An existing area for the same polygon is updated in place, keeping its
  /// id, its colour and anything typed into its description: a re-survey
  /// changes the numbers and the outline, not who the area is for.
  Future<ClientAreaUpsert> upsertFromSurvey({
    required String name,
    required List<LatLng> points,
    required int letterBoxEstimate,
    LetterBoxSplit? letterBoxSplit,
    String client = '',
    String? sourcePolygonId,
    DateTime? surveyedAt,
  }) async {
    final existing =
        await findForSurvey(sourcePolygonId: sourcePolygonId, name: name);
    final now = surveyedAt ?? DateTime.now();

    if (existing != null) {
      final updated = existing.copyWith(
        name: name,
        // Only overwrite the client when the survey actually names one —
        // a round labelled with no client must not blank out a client that
        // was set by hand in the editor.
        client: client.isEmpty ? existing.client : client,
        polygonPoints: points,
        letterBoxEstimate: letterBoxEstimate,
        letterBoxSplit: letterBoxSplit,
        sourcePolygonId: sourcePolygonId ?? existing.sourcePolygonId,
        surveyedAt: now,
        updatedAt: now,
      );
      await save(updated);
      return ClientAreaUpsert(saved: updated, previous: existing);
    }

    final created = ClientArea(
      id: '',
      name: name,
      client: client,
      polygonPoints: points,
      letterBoxEstimate: letterBoxEstimate,
      letterBoxSplit: letterBoxSplit,
      sourcePolygonId: sourcePolygonId,
      surveyedAt: now,
      createdAt: now,
      updatedAt: now,
    );
    final id = await add(created);
    return ClientAreaUpsert(saved: created.copyWith(id: id));
  }

  /// Undo an [upsertFromSurvey]: delete what it created, or write back what it
  /// replaced. Used by the track editor's session undo, so rolling back a
  /// letterbox-index update also rolls back the client-library numbers it
  /// produced — otherwise a quote would still be reading a count that no
  /// longer exists.
  Future<void> revertUpsert(ClientAreaUpsert upsert) async {
    final previous = upsert.previous;
    if (previous == null) {
      await delete(upsert.saved.id);
    } else {
      await save(previous);
    }
  }
}
