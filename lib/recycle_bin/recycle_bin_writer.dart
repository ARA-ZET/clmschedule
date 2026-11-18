// recycle_bin/recycle_bin_writer.dart
//
// Puts a copy of a deleted document into the Recycle Bin. Call it with the
// SAME WriteBatch or Transaction that performs the delete, so the delete and
// its copy commit together or not at all:
//
//   final batch = db.batch();
//   RecycleBinWriter(db).addToBatch(batch, RecycleBinRecord(
//     type: RecycleBinType.regularClient,
//     label: client.name,
//     originalPath: ref.path,
//     payload: snap.data()!,
//   ));
//   batch.delete(ref);
//   await batch.commit();
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'recycle_bin_entry.dart';

/// Fields stripped from every payload: they describe the document's old
/// life and would misfire if written back. `movedFrom` on a job list item
/// makes the folder function rename maps on restore.
const Set<String> _hazardousFields = {'movedFrom'};

class RecycleBinRecord {
  final RecycleBinType type;
  final String label;
  final String originalPath;
  final Map<String, dynamic> payload;
  final List<RecycleBinRelated> related;
  final Map<String, String> storagePaths;
  final List<String> ownedStorage;
  final String? payloadRef;

  const RecycleBinRecord({
    required this.type,
    required this.label,
    required this.originalPath,
    this.payload = const {},
    this.related = const [],
    this.storagePaths = const {},
    this.ownedStorage = const [],
    this.payloadRef,
  });
}

/// "Thabo (distributor)": the first name-like field of [data], then [kind].
String binLabel(Map<String, dynamic> data, String kind) {
  for (final key in const ['name', 'label', 'title', 'client', 'text']) {
    final v = data[key];
    if (v is String && v.trim().isNotEmpty) return '${v.trim()} ($kind)';
  }
  return 'Unnamed $kind';
}

class RecycleBinWriter {
  final FirebaseFirestore _db;
  RecycleBinWriter([FirebaseFirestore? db])
      : _db = db ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _bin =>
      _db.collection(kRecycleBinCollection);

  /// A fresh id, for callers that need it before writing (e.g. to name the
  /// Storage folder deleted files move into).
  DocumentReference<Map<String, dynamic>> newEntryRef() => _bin.doc();

  DocumentReference<Map<String, dynamic>> addToBatch(
    WriteBatch batch,
    RecycleBinRecord record, {
    DocumentReference<Map<String, dynamic>>? ref,
  }) {
    final entryRef = ref ?? newEntryRef();
    batch.set(entryRef, _data(record));
    return entryRef;
  }

  DocumentReference<Map<String, dynamic>> addToTxn(
    Transaction txn,
    RecycleBinRecord record, {
    DocumentReference<Map<String, dynamic>>? ref,
  }) {
    final entryRef = ref ?? newEntryRef();
    txn.set(entryRef, _data(record));
    return entryRef;
  }

  /// Deletes the document at [ref] into the bin — the copy and the delete in
  /// one batch — and returns the entry id (null if it was already gone).
  /// [label] names it in the bin from its data.
  Future<String?> moveDocToBin(
    DocumentReference<Map<String, dynamic>> ref, {
    required RecycleBinType type,
    required String Function(Map<String, dynamic> data) label,
  }) async {
    final snap = await ref.get();
    final data = snap.data();
    if (data == null) return null;
    final batch = _db.batch();
    final entryRef = addToBatch(
      batch,
      RecycleBinRecord(
        type: type,
        label: label(data),
        originalPath: ref.path,
        payload: data,
      ),
    );
    batch.delete(ref);
    await batch.commit();
    return entryRef.id;
  }

  /// Writes a bin entry on its own — for deletes that aren't a Firestore
  /// write (Cloud Files, where the objects were already moved).
  Future<DocumentReference<Map<String, dynamic>>> add(
    RecycleBinRecord record, {
    DocumentReference<Map<String, dynamic>>? ref,
  }) async {
    final entryRef = ref ?? newEntryRef();
    await entryRef.set(_data(record));
    return entryRef;
  }

  Map<String, dynamic> _data(RecycleBinRecord r) {
    final user = FirebaseAuth.instance.currentUser;
    final payload = Map<String, dynamic>.from(r.payload)
      ..removeWhere((k, _) => _hazardousFields.contains(k));
    return {
      'type': r.type.name,
      'tab': r.type.tab.name,
      'label': r.label,
      'originalPath': r.originalPath,
      'payload': payload,
      if (r.payloadRef != null) 'payloadRef': r.payloadRef,
      'related': [for (final x in r.related) x.toMap()],
      'storagePaths': r.storagePaths,
      'ownedStorage': r.ownedStorage,
      'deletedAt': FieldValue.serverTimestamp(),
      'deletedBy': {
        'uid': user?.uid ?? '',
        'email': user?.email ?? '',
        'name': user?.displayName ?? user?.email ?? '',
      },
      'expiresAt': Timestamp.fromDate(DateTime.now().add(kRecycleBinRetention)),
      // Explicit null so the bin's `restoredAt == null` query matches.
      'restoredAt': null,
    };
  }
}
