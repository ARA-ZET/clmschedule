import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/distributor.dart';
import '../services/firestore_service.dart';

final distributorRiverpod =
    riverpod.ChangeNotifierProvider<DistributorProvider>(
  (ref) => DistributorProvider(),
);

/// Lightweight provider that exposes a real-time stream of distributors.
/// Used by the digital ID card picker and any widget that only needs
/// the distributors list without the full ScheduleProvider overhead.
class DistributorProvider extends ChangeNotifier {
  final FirestoreService _firestoreService = FirestoreService();

  List<Distributor> _distributors = [];
  bool _loading = true;
  String? _error;
  StreamSubscription<List<Distributor>>? _sub;

  DistributorProvider() {
    _init();
  }

  List<Distributor> get distributors => _distributors;
  bool get loading => _loading;
  String? get error => _error;

  void _init() {
    _sub = _firestoreService.streamDistributors().listen(
      (list) {
        _distributors = list;
        _loading = false;
        _error = null;
        notifyListeners();
      },
      onError: (Object e) {
        _error = e.toString();
        _loading = false;
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
