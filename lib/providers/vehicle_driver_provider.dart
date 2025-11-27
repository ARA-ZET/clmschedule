import 'package:flutter/foundation.dart';
import '../models/vehicle.dart';
import '../services/vehicle_driver_service.dart';

class VehicleDriverProvider extends ChangeNotifier {
  final VehicleDriverService _service = VehicleDriverService();

  List<Vehicle> _vehicles = [];
  List<Driver> _drivers = [];
  Map<String, String> _dailyAssignments = {};
  List<DailyTrackingEntry> _trackingEntries = [];

  bool _isLoading = false;
  String? _error;

  // Getters
  List<Vehicle> get vehicles => _vehicles;
  List<Driver> get drivers => _drivers;
  Map<String, String> get dailyAssignments => _dailyAssignments;
  List<DailyTrackingEntry> get trackingEntries => _trackingEntries;
  bool get isLoading => _isLoading;
  String? get error => _error;

  List<Vehicle> get activeVehicles =>
      _vehicles.where((v) => v.isActive).toList();
  List<Driver> get activeDrivers => _drivers.where((d) => d.isActive).toList();

  // Initialize data
  Future<void> initialize() async {
    await loadVehicles();
    await loadDrivers();
    await _service.initializeSampleData(); // Initialize sample data if needed
  }

  // Vehicle operations
  Future<void> loadVehicles() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      _vehicles = await _service.getVehicles();
    } catch (e) {
      _error = 'Failed to load vehicles: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> addVehicle(Vehicle vehicle) async {
    try {
      await _service.addVehicle(vehicle);
      await loadVehicles(); // Refresh the list
    } catch (e) {
      _error = 'Failed to add vehicle: $e';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateVehicle(Vehicle vehicle) async {
    try {
      await _service.updateVehicle(vehicle);
      await loadVehicles(); // Refresh the list
    } catch (e) {
      _error = 'Failed to update vehicle: $e';
      notifyListeners();
      rethrow;
    }
  }

  // Driver operations
  Future<void> loadDrivers() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      _drivers = await _service.getDrivers();
    } catch (e) {
      _error = 'Failed to load drivers: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> addDriver(Driver driver) async {
    try {
      await _service.addDriver(driver);
      await loadDrivers(); // Refresh the list
    } catch (e) {
      _error = 'Failed to add driver: $e';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateDriver(Driver driver) async {
    try {
      await _service.updateDriver(driver);
      await loadDrivers(); // Refresh the list
    } catch (e) {
      _error = 'Failed to update driver: $e';
      notifyListeners();
      rethrow;
    }
  }

  // Assignment operations
  Future<void> loadDailyAssignments(DateTime date) async {
    try {
      _dailyAssignments = await _service.getVehicleAssignments(date);
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load assignments: $e';
      notifyListeners();
    }
  }

  Future<void> assignDriverToVehicle(
      String driverId, String vehicleId, DateTime date) async {
    try {
      _dailyAssignments[driverId] = vehicleId;
      await _service.saveVehicleAssignments(date, _dailyAssignments);
      notifyListeners();
    } catch (e) {
      _error = 'Failed to assign driver: $e';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> saveVehicleAssignments(
      DateTime date, Map<String, String> assignments) async {
    try {
      await _service.saveVehicleAssignments(date, assignments);
      _dailyAssignments = assignments;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to save assignments: $e';
      notifyListeners();
      rethrow;
    }
  }

  // Tracking entries
  Future<void> loadTrackingEntries(DateTime date) async {
    try {
      _trackingEntries = await _service.getTrackingEntries(date);
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load tracking entries: $e';
      notifyListeners();
    }
  }

  Future<void> saveTrackingEntry(DailyTrackingEntry entry) async {
    try {
      await _service.saveTrackingEntry(entry);
      await loadTrackingEntries(entry.date); // Refresh
    } catch (e) {
      _error = 'Failed to save tracking entry: $e';
      notifyListeners();
      rethrow;
    }
  }

  // Helper methods
  Vehicle? getVehicleById(String vehicleId) {
    try {
      return _vehicles.firstWhere((v) => v.id == vehicleId);
    } catch (e) {
      return null;
    }
  }

  Driver? getDriverById(String driverId) {
    try {
      return _drivers.firstWhere((d) => d.id == driverId);
    } catch (e) {
      return null;
    }
  }

  String? getAssignedVehicleId(String driverId) {
    return _dailyAssignments[driverId];
  }

  Vehicle? getAssignedVehicle(String driverId) {
    final vehicleId = getAssignedVehicleId(driverId);
    return vehicleId != null ? getVehicleById(vehicleId) : null;
  }

  DailyTrackingEntry? getTrackingEntry(String distributorId, DateTime date) {
    try {
      return _trackingEntries.firstWhere(
        (entry) =>
            entry.distributorId == distributorId &&
            entry.date.year == date.year &&
            entry.date.month == date.month &&
            entry.date.day == date.day,
      );
    } catch (e) {
      return null;
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
