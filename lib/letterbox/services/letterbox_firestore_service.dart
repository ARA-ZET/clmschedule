import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/letterbox_suburb.dart';

/// Reads and writes the per-suburb letterbox metadata documents.
///
/// Firestore path: `letterboxSuburbs/{suburbId}`. These documents hold no
/// geometry — only counts, curation status and bounds — so the whole
/// collection (613 suburbs) can be streamed in one query to drive the overview
/// choropleth and the curation progress view.
class LetterboxFirestoreService {
  static const String collection = 'letterboxSuburbs';
  static const String configCollection = 'letterboxConfig';

  final FirebaseFirestore? _injectedDb;

  /// Resolved lazily rather than in the initializer list so that subclasses
  /// which override every method — test fakes, chiefly — never touch
  /// `FirebaseFirestore.instance` and so do not require an initialised app.
  FirebaseFirestore get _db => _injectedDb ?? FirebaseFirestore.instance;

  LetterboxFirestoreService({FirebaseFirestore? db}) : _injectedDb = db;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(collection);

  /// Every suburb's metadata, live. One query drives the whole overview.
  Stream<List<LetterboxSuburb>> streamAll() {
    return _col.snapshots().map((snap) =>
        snap.docs.map((d) => LetterboxSuburb.fromMap(d.id, d.data())).toList());
  }

  Future<List<LetterboxSuburb>> getAll() async {
    final snap = await _col.get();
    return snap.docs
        .map((d) => LetterboxSuburb.fromMap(d.id, d.data()))
        .toList();
  }

  Future<LetterboxSuburb?> get(String suburbId) async {
    final doc = await _col.doc(suburbId).get();
    final data = doc.data();
    if (!doc.exists || data == null) return null;
    return LetterboxSuburb.fromMap(doc.id, data);
  }

  Stream<LetterboxSuburb?> watch(String suburbId) {
    return _col.doc(suburbId).snapshots().map((doc) {
      final data = doc.data();
      if (!doc.exists || data == null) return null;
      return LetterboxSuburb.fromMap(doc.id, data);
    });
  }

  /// Write the full metadata document for a suburb.
  Future<void> save(LetterboxSuburb suburb) async {
    await _col
        .doc(suburb.suburbId)
        .set(suburb.toMap(), SetOptions(merge: true));
  }

  /// Write many metadata documents at once.
  ///
  /// Firestore caps a batch at 500 writes, so this chunks. Saving 613 suburbs
  /// one document at a time is 613 sequential round trips — about two minutes
  /// from a browser; batched it is two requests.
  Future<void> saveAll(List<LetterboxSuburb> suburbs) async {
    const chunkSize = 500;
    for (var i = 0; i < suburbs.length; i += chunkSize) {
      final chunk = suburbs.skip(i).take(chunkSize);
      final batch = _db.batch();
      for (final suburb in chunk) {
        batch.set(
            _col.doc(suburb.suburbId), suburb.toMap(), SetOptions(merge: true));
      }
      await batch.commit();
    }
  }

  /// Remove a suburb's metadata document.
  ///
  /// Used when undoing a write that created the document in the first place —
  /// leaving an empty, zero-count document behind would show that suburb as
  /// curated-to-nothing rather than as never seeded.
  Future<void> delete(String suburbId) async {
    await _col.doc(suburbId).delete();
  }

  /// Clear the "new GPS drops have arrived" flag after a human has reviewed
  /// them. Deliberately separate from [save] so the refresh job and the
  /// curation UI never race each other over the whole document.
  Future<void> clearNewCandidatesFlag(String suburbId) async {
    await _col.doc(suburbId).update({
      'hasNewCandidates': false,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Tier bands, editable as business config rather than baked into code.
  /// Shape: `{ bands: [ {tier, minCount, maxCount}, … ] }`.
  Future<Map<String, dynamic>?> getTierConfig() async {
    final doc = await _db.collection(configCollection).doc('tiers').get();
    return doc.data();
  }
}
