import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/driver.dart';
import '../recycle_bin/recycle_bin_entry.dart';
import '../recycle_bin/recycle_bin_writer.dart';

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

  /// Stored under [Driver.id] — the distributor's id, so a dropsheet
  /// section's `driverId` is that distributor's id everywhere else too
  /// (payroll's driving-code default, the schedule).
  Future<String> addDriver(Driver driver) async {
    await _col.doc(driver.id).set(driver.toMap());
    return driver.id;
  }

  Future<void> updateDriver(Driver driver) async {
    await _col.doc(driver.id).update(driver.toMap());
  }

  /// Moves the driver to the Recycle Bin.
  Future<void> deleteDriver(String id) async {
    await RecycleBinWriter().moveDocToBin(
      _col.doc(id),
      type: RecycleBinType.driver,
      label: (d) => binLabel(d, 'driver'),
    );
  }
}
