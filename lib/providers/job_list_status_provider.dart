import 'package:flutter/material.dart';
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

      if (snapshot.docs.isEmpty) {
        // Initialize with default statuses if none exist
        await initializeDefaultStatuses();
      } else {
        _statuses = snapshot.docs.map((doc) {
          final data = doc.data();
          data['id'] = doc.id; // Ensure the document ID is set
          return CustomJobListStatus.fromMap(data);
        }).toList();
      }
    } catch (e) {
      _error = 'Error loading job list statuses: $e';
      print(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Add a new status
  Future<void> addStatus(String label, Color color) async {
    try {
      _error = null;

      final docRef = await _firestore.collection('customJobListStatuses').add({
        'label': label,
        'color': color.value,
        'isDefault': false,
      });

      final newStatus = CustomJobListStatus(
        id: docRef.id,
        label: label,
        color: color,
        isDefault: false,
      );

      _statuses.add(newStatus);
      _statuses.sort((a, b) => a.label.compareTo(b.label));
      notifyListeners();
    } catch (e) {
      _error = 'Error adding status: $e';
      print(_error);
      notifyListeners();
    }
  }

  // Update an existing status
  Future<void> updateStatus(String id, String label, Color color) async {
    try {
      _error = null;

      await _firestore.collection('customJobListStatuses').doc(id).update({
        'label': label,
        'color': color.value,
      });

      final index = _statuses.indexWhere((status) => status.id == id);
      if (index != -1) {
        _statuses[index] = _statuses[index].copyWith(
          label: label,
          color: color,
        );
        _statuses.sort((a, b) => a.label.compareTo(b.label));
        notifyListeners();
      }
    } catch (e) {
      _error = 'Error updating status: $e';
      print(_error);
      notifyListeners();
    }
  }

  // Delete a status (only non-default statuses can be deleted)
  Future<void> deleteStatus(String id) async {
    try {
      _error = null;

      final status = _statuses.firstWhere((s) => s.id == id);
      if (status.isDefault) {
        _error = 'Cannot delete default status';
        notifyListeners();
        return;
      }

      await _firestore.collection('customJobListStatuses').doc(id).delete();
      _statuses.removeWhere((status) => status.id == id);
      notifyListeners();
    } catch (e) {
      _error = 'Error deleting status: $e';
      print(_error);
      notifyListeners();
    }
  }

  // Get status by ID
  CustomJobListStatus? getStatusById(String id) {
    try {
      return _statuses.firstWhere((status) => status.id == id);
    } catch (e) {
      return null;
    }
  }

  // Get status by label (for backwards compatibility)
  CustomJobListStatus? getStatusByLabel(String label) {
    try {
      return _statuses.firstWhere((status) => status.label == label);
    } catch (e) {
      return null;
    }
  }

  // Initialize default statuses based on the original enum values
  Future<void> initializeDefaultStatuses() async {
    final defaultStatuses = [
      CustomJobListStatus(
        id: 'order_confirmed_not_paid',
        label: 'Order Confirmed Not Paid',
        color: Colors.blue.shade800, // Darker blue
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'job_under_way',
        label: 'Job Under Way',
        color: Colors.orange.shade800, // Darker orange
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'job_done',
        label: 'Job Done',
        color: Colors.green.shade800, // Darker green
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'report_compliled',
        label: 'Report Compliled',
        color: Colors.green.shade700, // Darker green (slightly different shade)
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'outstanding',
        label: 'Outstanding',
        color: Colors.red.shade800, // Darker red
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'invoice_sent',
        label: 'Invoice sent',
        color: Colors.purple.shade800, // Darker purple
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'standby',
        label: 'Standby',
        color: Colors.grey.shade700, // Darker grey
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'printing_order_confirmed',
        label: 'Printing - order confirmed',
        color: Colors.teal.shade800, // Darker teal
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'printing_artwork_submitted',
        label: 'Printing - Artwork submitted',
        color: Colors.teal.shade700, // Darker teal (different shade)
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'printing_artwork_approved',
        label: 'Printing - Artwork approved',
        color: Colors.teal.shade600, // Darker teal (different shade)
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'printing_awaiting_payment',
        label: 'Printing - Awaiting payment',
        color: Colors.teal.shade900, // Darkest teal
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'printing_under_way',
        label: 'Printing under way',
        color: Colors.orange.shade700, // Darker orange (different shade)
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'printing_ready_for_collection',
        label: 'Printing - ready for collection',
        color: Colors.teal.shade500, // Medium-dark teal
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'query',
        label: 'Query',
        color: Colors.red.shade700, // Darker red (different shade)
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'order_confirmed_paid',
        label: 'Order Confirmed Paid',
        color: Colors.blue.shade700, // Darker blue (different shade)
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'report_sent',
        label: 'Report Sent',
        color: Colors.purple.shade700, // Darker purple (different shade)
        isDefault: true,
      ),
      CustomJobListStatus(
        id: 'paid',
        label: 'Paid',
        color: Colors.green.shade700, // Darker green (different shade)
        isDefault: true,
      ),
    ];

    try {
      final batch = _firestore.batch();

      for (final status in defaultStatuses) {
        final docRef =
            _firestore.collection('customJobListStatuses').doc(status.id);
        batch.set(docRef, status.toMap());
      }

      await batch.commit();
      _statuses = defaultStatuses;
      _statuses.sort((a, b) => a.label.compareTo(b.label));
      print(
          'JobListStatusProvider: Initialized ${defaultStatuses.length} default statuses');
    } catch (e) {
      _error = 'Error initializing default statuses: $e';
      print(_error);
    }

    notifyListeners();
  }

  // Clear error message
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
