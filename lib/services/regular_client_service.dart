// services/regular_client_service.dart
//
// CRUD over the regular-client allocation plans: `regularClients/{id}`.
// Same shape and habits as ClientAreaService.
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/regular_client.dart';

class RegularClientService {
  static const String collection = 'regularClients';

  final FirebaseFirestore? _injectedDb;

  FirebaseFirestore get _db => _injectedDb ?? FirebaseFirestore.instance;

  RegularClientService({FirebaseFirestore? firestore}) : _injectedDb = firestore;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(collection);

  /// Every regular client, live, sorted by name.
  Stream<List<RegularClient>> streamAll() => _col.snapshots().map((snap) {
        final list = snap.docs.map(RegularClient.fromFirestore).toList();
        list.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return list;
      });

  Stream<RegularClient?> stream(String id) => _col
      .doc(id)
      .snapshots()
      .map((doc) => doc.exists ? RegularClient.fromFirestore(doc) : null);

  Future<RegularClient?> get(String id) async {
    if (id.isEmpty) return null;
    final doc = await _col.doc(id).get();
    return doc.exists ? RegularClient.fromFirestore(doc) : null;
  }

  /// Create a regular client and return its new id.
  Future<String> add(RegularClient client) async {
    final ref = await _col.add({
      ...client.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<void> save(RegularClient client) async {
    await _col.doc(client.id).set({
      ...client.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> delete(String id) async {
    if (id.isEmpty) return;
    await _col.doc(id).delete();
  }
}
