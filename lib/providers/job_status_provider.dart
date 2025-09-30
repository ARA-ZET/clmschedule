import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../models/custom_job_status.dart';

class JobStatusProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<CustomJobStatus> _statuses = [];
  bool _isLoading = false;

  List<CustomJobStatus> get statuses => List.unmodifiable(_statuses);
  bool get isLoading => _isLoading;

  JobStatusProvider() {
    loadStatuses();
  }

  /// Load all job statuses from Firestore
  Future<void> loadStatuses() async {
    _isLoading = true;
    notifyListeners();

    try {
      final QuerySnapshot snapshot =
          await _firestore.collection('jobStatuses').orderBy('order').get();

      if (snapshot.docs.isEmpty) {
        // Initialize with default statuses if none exist
        await initializeDefaultStatuses();
      } else {
        _statuses = snapshot.docs
            .map((doc) =>
                CustomJobStatus.fromMap(doc.data() as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      print('Error loading job statuses: $e');
      // Fallback to default statuses
      _statuses = CustomJobStatus.getDefaultStatuses();
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Initialize default statuses in Firestore
  Future<void> initializeDefaultStatuses() async {
    final defaultStatuses = CustomJobStatus.getDefaultStatuses();

    final batch = _firestore.batch();
    for (final status in defaultStatuses) {
      final docRef = _firestore.collection('jobStatuses').doc(status.id);
      batch.set(docRef, status.toMap());
    }

    await batch.commit();
    _statuses = defaultStatuses;
  }

  /// Add a new job status
  Future<void> addStatus(CustomJobStatus status) async {
    try {
      await _firestore
          .collection('jobStatuses')
          .doc(status.id)
          .set(status.toMap());

      _statuses.add(status);
      _sortStatuses();
      notifyListeners();
    } catch (e) {
      print('Error adding job status: $e');
      throw Exception('Failed to add job status');
    }
  }

  /// Update an existing job status
  Future<void> updateStatus(CustomJobStatus status) async {
    try {
      await _firestore
          .collection('jobStatuses')
          .doc(status.id)
          .update(status.toMap());

      final index = _statuses.indexWhere((s) => s.id == status.id);
      if (index != -1) {
        _statuses[index] = status;
        _sortStatuses();
        notifyListeners();
      }
    } catch (e) {
      print('Error updating job status: $e');
      throw Exception('Failed to update job status');
    }
  }

  /// Delete a job status (only if not default)
  Future<void> deleteStatus(String statusId) async {
    final status = _statuses.firstWhere((s) => s.id == statusId);
    if (status.isDefault) {
      throw Exception('Cannot delete default status');
    }

    try {
      await _firestore.collection('jobStatuses').doc(statusId).delete();

      _statuses.removeWhere((s) => s.id == statusId);
      notifyListeners();
    } catch (e) {
      print('Error deleting job status: $e');
      throw Exception('Failed to delete job status');
    }
  }

  /// Get a status by ID
  CustomJobStatus? getStatusById(String id) {
    try {
      final matchingStatuses = _statuses.where((status) => status.id == id);
      if (matchingStatuses.isNotEmpty) {
        return matchingStatuses.first;
      }
      return null;
    } catch (e) {
      print('Error getting status by ID $id: $e');
      return null;
    }
  }

  /// Get default status (fallback if no status found)
  CustomJobStatus getDefaultStatus() {
    final scheduledStatus = getStatusById('scheduled');
    if (scheduledStatus != null) {
      return scheduledStatus;
    }

    // Fallback to first available status
    if (_statuses.isNotEmpty) {
      return _statuses.first;
    }

    // Last resort fallback
    return const CustomJobStatus(
      id: 'scheduled',
      label: 'Scheduled',
      color: Colors.orange,
      isDefault: true,
    );
  }

  /// Sort statuses by order
  void _sortStatuses() {
    _statuses.sort((a, b) => a.order.compareTo(b.order));
  }

  /// Get the next available order number
  int getNextOrder() {
    if (_statuses.isEmpty) return 0;
    return _statuses.map((s) => s.order).reduce((a, b) => a > b ? a : b) + 1;
  }

  /// Generate a unique ID for a new status
  String generateStatusId(String label) {
    String baseId = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    String id = baseId;
    int counter = 1;

    while (_statuses.any((s) => s.id == id)) {
      id = '${baseId}_$counter';
      counter++;
    }

    return id;
  }

  /// Reorder statuses
  Future<void> reorderStatuses(List<CustomJobStatus> newOrder) async {
    try {
      final batch = _firestore.batch();

      for (int i = 0; i < newOrder.length; i++) {
        final status = newOrder[i].copyWith(order: i);
        final docRef = _firestore.collection('jobStatuses').doc(status.id);
        batch.update(docRef, {'order': i});
      }

      await batch.commit();

      _statuses =
          newOrder.map((s) => s.copyWith(order: newOrder.indexOf(s))).toList();
      notifyListeners();
    } catch (e) {
      print('Error reordering job statuses: $e');
      throw Exception('Failed to reorder job statuses');
    }
  }
}
