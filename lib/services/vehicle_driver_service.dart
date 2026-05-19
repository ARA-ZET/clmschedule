import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/vehicle.dart';

class VehicleDriverService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Vehicle management
  Future<List<Vehicle>> getVehicles() async {
    try {
      final snapshot = await _firestore.collection('vehicles').get();
      return snapshot.docs.map((doc) => Vehicle.fromFirestore(doc)).toList();
    } catch (e) {
      print('Error getting vehicles: $e');
      return [];
    }
  }

  Future<void> addVehicle(Vehicle vehicle) async {
    try {
      await _firestore.collection('vehicles').add(vehicle.toMap());
    } catch (e) {
      print('Error adding vehicle: $e');
      rethrow;
    }
  }

  Future<void> updateVehicle(Vehicle vehicle) async {
    try {
      await _firestore
          .collection('vehicles')
          .doc(vehicle.id)
          .update(vehicle.toMap());
    } catch (e) {
      print('Error updating vehicle: $e');
      rethrow;
    }
  }

  // Driver management
  Future<List<Driver>> getDrivers() async {
    try {
      final snapshot = await _firestore.collection('drivers').get();
      return snapshot.docs.map((doc) => Driver.fromFirestore(doc)).toList();
    } catch (e) {
      print('Error getting drivers: $e');
      return [];
    }
  }

  Future<void> addDriver(Driver driver) async {
    try {
      await _firestore.collection('drivers').add(driver.toMap());
    } catch (e) {
      print('Error adding driver: $e');
      rethrow;
    }
  }

  Future<void> updateDriver(Driver driver) async {
    try {
      await _firestore
          .collection('drivers')
          .doc(driver.id)
          .update(driver.toMap());
    } catch (e) {
      print('Error updating driver: $e');
      rethrow;
    }
  }

  // Daily tracking entries
  Future<List<DailyTrackingEntry>> getTrackingEntries(DateTime date) async {
    try {
      final dateString =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final snapshot = await _firestore
          .collection('tracking_entries')
          .where('date', isEqualTo: dateString)
          .get();

      return snapshot.docs
          .map((doc) => DailyTrackingEntry.fromFirestore(doc))
          .toList();
    } catch (e) {
      print('Error getting tracking entries: $e');
      return [];
    }
  }

  Future<void> saveTrackingEntry(DailyTrackingEntry entry) async {
    try {
      final dateString =
          '${entry.date.year}-${entry.date.month.toString().padLeft(2, '0')}-${entry.date.day.toString().padLeft(2, '0')}';
      final docId = '${dateString}_${entry.distributorId}';

      await _firestore
          .collection('tracking_entries')
          .doc(docId)
          .set(entry.toMap(), SetOptions(merge: true));
    } catch (e) {
      print('Error saving tracking entry: $e');
      rethrow;
    }
  }

  // Assign driver to vehicle
  Future<void> assignDriverToVehicle(String driverId, String vehicleId) async {
    try {
      await _firestore.collection('drivers').doc(driverId).update({
        'vehicleId': vehicleId,
      });
    } catch (e) {
      print('Error assigning driver to vehicle: $e');
      rethrow;
    }
  }

  // Get vehicle assignments for a date
  Future<Map<String, String>> getVehicleAssignments(DateTime date) async {
    try {
      final dateString =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final snapshot = await _firestore
          .collection('vehicle_assignments')
          .doc(dateString)
          .get();

      if (snapshot.exists) {
        final data = Map<String, dynamic>.from(snapshot.data() as Map);
        return Map<String, String>.from(data['assignments'] ?? {});
      }
      return {};
    } catch (e) {
      print('Error getting vehicle assignments: $e');
      return {};
    }
  }

  Future<void> saveVehicleAssignments(
      DateTime date, Map<String, String> assignments) async {
    try {
      final dateString =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      await _firestore.collection('vehicle_assignments').doc(dateString).set({
        'date': dateString,
        'assignments': assignments,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error saving vehicle assignments: $e');
      rethrow;
    }
  }

  // Initialize with sample data
  Future<void> initializeSampleData() async {
    try {
      // Check if data already exists
      final vehiclesSnapshot =
          await _firestore.collection('vehicles').limit(1).get();
      if (vehiclesSnapshot.docs.isNotEmpty) return;

      // Add sample vehicles
      final sampleVehicles = [
        Vehicle(
            id: '',
            name: 'Mahindra',
            type: 'truck',
            plateNumber: 'CLM001',
            isActive: true),
        Vehicle(
            id: '',
            name: 'Hyundai',
            type: 'van',
            plateNumber: 'CLM002',
            isActive: true),
        Vehicle(
            id: '',
            name: 'Traffic light Car',
            type: 'car',
            plateNumber: 'CLM003',
            isActive: true),
      ];

      for (final vehicle in sampleVehicles) {
        await addVehicle(vehicle);
      }

      // Add sample drivers
      final sampleDrivers = [
        Driver(
            id: '',
            name: 'Francis',
            phone: '064 144 9903',
            vehicleId: '',
            isActive: true),
        Driver(
            id: '',
            name: 'Tanaka',
            phone: '081 7269 468',
            vehicleId: '',
            isActive: true),
        Driver(
            id: '',
            name: 'Samuel',
            phone: '066 052 6604',
            vehicleId: '',
            isActive: true),
        Driver(
            id: '',
            name: 'Talent',
            phone: '067 926 5006',
            vehicleId: '',
            isActive: true),
      ];

      for (final driver in sampleDrivers) {
        await addDriver(driver);
      }

      print('Sample data initialized successfully');
    } catch (e) {
      print('Error initializing sample data: $e');
    }
  }
}
