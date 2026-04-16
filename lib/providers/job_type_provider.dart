import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/custom_job_type.dart';

final jobTypeRiverpod = riverpod.ChangeNotifierProvider<JobTypeProvider>(
    (ref) => JobTypeProvider());

class JobTypeProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<CustomJobType> _jobTypes = [];
  bool _isLoading = true;
  StreamSubscription? _subscription;

  List<CustomJobType> get jobTypes => List.unmodifiable(_jobTypes);
  bool get isLoading => _isLoading;

  JobTypeProvider() {
    _listenToJobTypes();
  }

  void _listenToJobTypes() {
    _subscription = _firestore
        .collection('customJobTypes')
        .orderBy('order')
        .snapshots()
        .listen((snapshot) {
      if (snapshot.docs.isEmpty && _isLoading) {
        // First-time setup: seed defaults into Firestore
        _initializeDefaults();
      } else {
        _jobTypes = snapshot.docs
            .map((doc) => CustomJobType.fromMap(doc.data()))
            .toList();
        _isLoading = false;
        notifyListeners();
      }
    }, onError: (e) {
      if (kDebugMode) {
        print('Error listening to job types: $e');
      }
      _isLoading = false;
      notifyListeners();
    });
  }

  Future<void> _initializeDefaults() async {
    final defaults = CustomJobType.getDefaults();
    final batch = _firestore.batch();
    for (final jt in defaults) {
      batch.set(_firestore.collection('customJobTypes').doc(jt.id), jt.toMap());
    }
    await batch.commit();
    // Stream listener will pick up the newly written docs automatically
  }

  Future<void> addJobType(String label) async {
    final id = _generateId(label);
    final jobType = CustomJobType(
      id: id,
      label: label,
      order: _getNextOrder(),
    );

    await _firestore.collection('customJobTypes').doc(id).set(jobType.toMap());

    _jobTypes.add(jobType);
    _sortJobTypes();
    notifyListeners();
  }

  Future<void> updateJobType(String id, String label) async {
    final index = _jobTypes.indexWhere((jt) => jt.id == id);
    if (index == -1) return;

    final updated = _jobTypes[index].copyWith(label: label);
    await _firestore
        .collection('customJobTypes')
        .doc(id)
        .update({'label': label});

    _jobTypes[index] = updated;
    notifyListeners();
  }

  Future<void> deleteJobType(String id) async {
    final jt = _jobTypes.firstWhere((j) => j.id == id);
    if (jt.isDefault) {
      throw Exception('Cannot delete default job type');
    }

    await _firestore.collection('customJobTypes').doc(id).delete();
    _jobTypes.removeWhere((j) => j.id == id);
    notifyListeners();
  }

  CustomJobType? getJobTypeById(String id) {
    try {
      return _jobTypes.firstWhere((jt) => jt.id == id);
    } catch (e) {
      return null;
    }
  }

  String getJobTypeLabel(String id) {
    return getJobTypeById(id)?.label ?? id;
  }

  void _sortJobTypes() {
    _jobTypes.sort((a, b) => a.order.compareTo(b.order));
  }

  int _getNextOrder() {
    if (_jobTypes.isEmpty) return 0;
    return _jobTypes.map((jt) => jt.order).reduce((a, b) => a > b ? a : b) + 1;
  }

  String _generateId(String label) {
    String baseId = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    String id = baseId;
    int counter = 1;
    while (_jobTypes.any((jt) => jt.id == id)) {
      id = '${baseId}_$counter';
      counter++;
    }
    return id;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
