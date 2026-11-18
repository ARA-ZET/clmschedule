// services/regular_client_service.dart
//
// CRUD over the regular-client allocation plans: `regularClients/{id}`.
// Same shape and habits as ClientAreaService.
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/regular_client.dart';
import '../shareable_maps/models/shareable_map.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import '../recycle_bin/recycle_bin_entry.dart';
import '../recycle_bin/recycle_bin_writer.dart';

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
      if (client.map != null)
        'map': RegularClient.mapToFirestore(client.map!),
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

  /// Write [client]'s own map alone, leaving the plan as it is.
  Future<void> saveMap(String id, ShareableMap map) async {
    await _col.doc(id).set({
      'map': RegularClient.mapToFirestore(map),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// A copy of gallery map [mapId] for a regular client to own. Only reads
  /// the gallery map: it belongs to a real client and is never changed here.
  Future<ShareableMap> copyFromGallery(String monthKey, String mapId,
      {ShareableMapsFirestoreService? maps}) async {
    final source = await (maps ?? ShareableMapsFirestoreService())
        .getMap(monthKey, mapId);
    if (source == null) {
      throw StateError('That map is no longer in the gallery.');
    }
    return RegularClient.templateFrom(source);
  }

  /// [client] with its own map, copying it from the gallery map it was made
  /// from when it predates plans owning their map. The copy keeps the
  /// polygon ids, so the plan still matches it.
  Future<RegularClient> ensureOwnMap(RegularClient client,
      {ShareableMapsFirestoreService? maps}) async {
    if (client.map != null) return client;
    final copy =
        await copyFromGallery(client.mapMonthKey, client.mapId, maps: maps);
    await saveMap(client.id, copy);
    return client.copyWith(map: copy);
  }

  /// Moves the client (with its own map copy) to the Recycle Bin.
  Future<void> delete(String id) async {
    if (id.isEmpty) return;
    await RecycleBinWriter().moveDocToBin(
      _col.doc(id),
      type: RecycleBinType.regularClient,
      label: (d) => binLabel(d, 'regular client'),
    );
  }
}
