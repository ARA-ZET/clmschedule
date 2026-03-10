import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/custom_job_list_status.dart';

class JobListStatusProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<CustomJobListStatus> _statuses = [];
  bool _isLoading = false;
  String? _error;

  List<CustomJobListStatus> get statuses => List.unmodifiable(_statuses);
  bool get isLoading => _isLoading;
  String? get error => _error;

  JobListStatusProvider() {
    loadStatuses();
  }

  // Load statuses from Firestore
  Future<void> loadStatuses() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final snapshot = await _firestore
          .collection('customJobListStatuses')
          .orderBy('label')
          .get();

      _statuses = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id; // Ensure the document ID is set
        return CustomJobListStatus.fromMap(data);
      }).toList();
    } catch (e) {
      _error = 'Error loading job list statuses: $e';
      if (kDebugMode) {
        print(_error);
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Add a new status
  Future<void> addStatus(String label, Color color,
      {List<String> hiddenForJobTypes = const []}) async {
    try {
      _error = null;

      final docRef = await _firestore.collection('customJobListStatuses').add({
        'label': label,
        'color': color.toARGB32(),
        'isDefault': false,
        'hiddenForJobTypes': hiddenForJobTypes,
      });

      final newStatus = CustomJobListStatus(
        id: docRef.id,
        label: label,
        color: color,
        isDefault: false,
        hiddenForJobTypes: hiddenForJobTypes,
      );

      _statuses.add(newStatus);
      _statuses.sort((a, b) => a.label.compareTo(b.label));
      notifyListeners();
    } catch (e) {
      _error = 'Error adding status: $e';
      if (kDebugMode) {
        print(_error);
      }
      notifyListeners();
    }
  }

  // Update an existing status
  Future<void> updateStatus(String id, String label, Color color,
      {List<String>? hiddenForJobTypes}) async {
    try {
      _error = null;

      final updateData = <String, dynamic>{
        'label': label,
        'color': color.toARGB32(),
      };
      if (hiddenForJobTypes != null) {
        updateData['hiddenForJobTypes'] = hiddenForJobTypes;
      }

      await _firestore
          .collection('customJobListStatuses')
          .doc(id)
          .update(updateData);

      final index = _statuses.indexWhere((status) => status.id == id);
      if (index != -1) {
        _statuses[index] = _statuses[index].copyWith(
          label: label,
          color: color,
          hiddenForJobTypes: hiddenForJobTypes,
        );
        _statuses.sort((a, b) => a.label.compareTo(b.label));
        notifyListeners();
      }
    } catch (e) {
      _error = 'Error updating status: $e';
      if (kDebugMode) {
        print(_error);
      }
      notifyListeners();
    }
  }

  // Delete a status
  Future<void> deleteStatus(String id) async {
    try {
      _error = null;

      final status = getStatusById(id);
      if (status == null) {
        _error = 'Status not found';
        notifyListeners();
        return;
      }

      await _firestore.collection('customJobListStatuses').doc(id).delete();
      _statuses.removeWhere((status) => status.id == id);
      notifyListeners();
    } catch (e) {
      _error = 'Error deleting status: $e';
      if (kDebugMode) {
        print(_error);
      }
      notifyListeners();
    }
  }

  // Get status by ID
  CustomJobListStatus? getStatusById(String id) {
    for (final status in _statuses) {
      if (status.id == id) {
        return status;
      }
    }
    return null;
  }

  // Get status by label (for backwards compatibility)
  CustomJobListStatus? getStatusByLabel(String label) {
    for (final status in _statuses) {
      if (status.label == label) {
        return status;
      }
    }
    return null;
  }

  // Get statuses filtered for a specific job type
  List<CustomJobListStatus> getStatusesForJobType(String jobTypeId) {
    return _statuses
        .where((status) => !status.hiddenForJobTypes.contains(jobTypeId))
        .toList();
  }

  // Clear error message
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
