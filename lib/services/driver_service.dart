import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/driver.dart';

/// CRUD for `/drivers/{id}` (global collection, like `/distributors`).
class DriverService {
  final FirebaseFirestore _firestore;

  DriverService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('drivers');

  Stream<List<Driver>> streamDrivers() {
    return _col.orderBy('name').snapshots().map(
          (s) => s.docs.map((d) => Driver.fromMap(d.id, d.data())).toList(),
        );
  }

  Future<String> addDriver(Driver driver) async {
    final ref = await _col.add(driver.toMap());
    return ref.id;
  }

  Future<void> updateDriver(Driver driver) async {
    await _col.doc(driver.id).update(driver.toMap());
  }

  Future<void> deleteDriver(String id) async {
    await _col.doc(id).delete();
  }
}
