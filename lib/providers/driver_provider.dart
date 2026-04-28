import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/driver.dart';
import '../services/driver_service.dart';

final driverServiceRiverpod =
    riverpod.Provider<DriverService>((ref) => DriverService());

final driverRiverpod = riverpod.ChangeNotifierProvider<DriverProvider>(
  (ref) => DriverProvider(ref.read(driverServiceRiverpod)),
);

class DriverProvider extends ChangeNotifier {
  final DriverService _service;
  StreamSubscription<List<Driver>>? _sub;

  List<Driver> _drivers = [];
  bool _isLoading = false;
  String? _error;

  DriverProvider(this._service) {
    _start();
  }

  List<Driver> get drivers => _drivers;
  List<Driver> get activeDrivers =>
      _drivers.where((d) => d.active).toList(growable: false);
  bool get isLoading => _isLoading;
  String? get error => _error;

  void _start() {
    _isLoading = true;
    _sub = _service.streamDrivers().listen(
      (list) {
        _drivers = list;
        _isLoading = false;
        _error = null;
        notifyListeners();
      },
      onError: (e) {
        _error = e.toString();
        _isLoading = false;
        notifyListeners();
      },
    );
  }

  Driver? byId(String id) {
    for (final d in _drivers) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<void> add(Driver d) => _service.addDriver(d);
  Future<void> update(Driver d) => _service.updateDriver(d);
  Future<void> delete(String id) => _service.deleteDriver(id);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
