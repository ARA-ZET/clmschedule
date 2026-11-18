// recycle_bin/recycle_bin_service.dart
//
// Lists, restores and purges Recycle Bin entries. Restoring hands the entry to
// the [RecycleBinHandler] registered for its type (see recycle_bin_handlers.dart);
// purging goes through the admin-only `recycleBin` callable, because clients
// may never delete bin entries themselves (firestore.rules).
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import 'recycle_bin_entry.dart';
import 'recycle_bin_handlers.dart';
import 'recycle_bin_payload_store.dart';

final recycleBinServiceRiverpod = riverpod.Provider<RecycleBinService>(
  (ref) => RecycleBinService(handlers: buildRecycleBinHandlers(ref)),
);

/// What a handler needs to mark its entry restored in the same write that
/// puts the item back.
class RestoreContext {
  final DocumentReference<Map<String, dynamic>> entryRef;
  const RestoreContext(this.entryRef);

  Map<String, dynamic> get restoredFields {
    final user = FirebaseAuth.instance.currentUser;
    return {
      'restoredAt': FieldValue.serverTimestamp(),
      'restoredBy': {
        'uid': user?.uid ?? '',
        'name': user?.displayName ?? user?.email ?? '',
      },
    };
  }

  void markRestoredInTxn(Transaction txn) =>
      txn.update(entryRef, restoredFields);

  void markRestoredInBatch(WriteBatch batch) =>
      batch.update(entryRef, restoredFields);

  Future<void> markRestored() => entryRef.update(restoredFields);
}

/// Puts one type of deleted item back. Throws [RestoreConflict] when the
/// original id or path has been taken again — restoring never overwrites.
abstract class RecycleBinHandler {
  Future<void> restore(RecycleBinEntry entry, RestoreContext ctx);
}

/// Restores a plain document (plus its [RecycleBinEntry.related] side docs)
/// under its original id, in one transaction with marking the entry restored.
class DocRestoreHandler implements RecycleBinHandler {
  final FirebaseFirestore _db;

  /// Describes the item in the conflict message ("a client named …").
  final String noun;

  /// Runs after a successful restore (e.g. bump a reference-cache version).
  final Future<void> Function(RecycleBinEntry entry)? afterRestore;

  DocRestoreHandler({
    required this.noun,
    this.afterRestore,
    FirebaseFirestore? db,
  }) : _db = db ?? FirebaseFirestore.instance;

  @override
  Future<void> restore(RecycleBinEntry entry, RestoreContext ctx) async {
    final ref = _db.doc(entry.originalPath);
    final payload = await resolvePayload(entry);
    await _db.runTransaction((txn) async {
      final current = await txn.get(ref);
      if (current.exists) {
        throw RestoreConflict('a $noun with the same id exists again');
      }
      final relatedRefs = [for (final r in entry.related) _db.doc(r.path)];
      final relatedSnaps = [for (final r in relatedRefs) await txn.get(r)];
      txn.set(ref, payload);
      for (var i = 0; i < relatedRefs.length; i++) {
        // A side doc whose id was reused meanwhile stays as it is.
        if (!relatedSnaps[i].exists) {
          txn.set(relatedRefs[i], entry.related[i].data);
        }
      }
      ctx.markRestoredInTxn(txn);
    });
    await afterRestore?.call(entry);
  }
}

class RecycleBinService {
  final FirebaseFirestore _db;
  final Map<RecycleBinType, RecycleBinHandler> handlers;

  RecycleBinService({required this.handlers, FirebaseFirestore? db})
      : _db = db ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _bin =>
      _db.collection(kRecycleBinCollection);

  /// Items still in the bin for [tab], newest first.
  Stream<List<RecycleBinEntry>> watchTab(RecycleBinTab tab) {
    return _bin
        .where('tab', isEqualTo: tab.name)
        .where('restoredAt', isNull: true)
        .orderBy('deletedAt', descending: true)
        .limit(300)
        .snapshots()
        .map((s) => s.docs
            .map(RecycleBinEntry.fromDoc)
            .whereType<RecycleBinEntry>()
            .toList());
  }

  bool canRestore(RecycleBinEntry entry) => handlers.containsKey(entry.type);

  /// Puts [entry] back where it was. Throws [RestoreConflict] if its place
  /// has been taken again.
  Future<void> restore(RecycleBinEntry entry) async {
    final handler = handlers[entry.type];
    if (handler == null) {
      throw StateError('No restore handler for ${entry.type.name}');
    }
    await handler.restore(entry, RestoreContext(_bin.doc(entry.id)));
  }

  /// Restores the entry with [id] — for the "Restore" action on the SnackBar
  /// shown right after a delete.
  Future<void> restoreById(String id) async {
    final entry = RecycleBinEntry.fromDoc(await _bin.doc(id).get());
    if (entry == null || entry.restoredAt != null) {
      throw const RestoreConflict('it is no longer in the Recycle Bin');
    }
    await restore(entry);
  }

  /// Admin only (checked server-side): deletes the entries and any Storage
  /// they hold, for good.
  Future<int> purge(List<String> ids) => _call({'action': 'purge', 'ids': ids});

  /// Admin only: empties one tab of the bin.
  Future<int> emptyTab(RecycleBinTab tab) =>
      _call({'action': 'emptyTab', 'tab': tab.name});

  Future<int> _call(Map<String, dynamic> data) async {
    final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
        .httpsCallable('recycleBin',
            options: HttpsCallableOptions(timeout: const Duration(minutes: 9)))
        .call<Map<String, dynamic>>(data);
    return (result.data['purged'] as num?)?.toInt() ?? 0;
  }
}
