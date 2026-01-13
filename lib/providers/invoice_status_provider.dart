import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/custom_invoice_status.dart';

class InvoiceStatusProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<CustomInvoiceStatus> _statuses = [];
  bool _isLoading = false;
  String? _error;

  List<CustomInvoiceStatus> get statuses => List.unmodifiable(_statuses);
  bool get isLoading => _isLoading;
  String? get error => _error;

  InvoiceStatusProvider() {
    loadStatuses();
  }

  // Load statuses from Firestore
  Future<void> loadStatuses() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final snapshot = await _firestore
          .collection('customInvoiceStatuses')
          .orderBy('label')
          .get();

      _statuses = snapshot.docs.map((doc) {
        final data = doc.data();
        data['id'] = doc.id; // Ensure the document ID is set
        return CustomInvoiceStatus.fromMap(data);
      }).toList();
    } catch (e) {
      _error = 'Error loading invoice statuses: $e';
      if (kDebugMode) {
        print(_error);
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Add a new status
  Future<void> addStatus(String label, Color color) async {
    try {
      _error = null;

      final docRef = await _firestore.collection('customInvoiceStatuses').add({
        'label': label,
        'color': color.toARGB32(),
        'isDefault': false,
      });

      final newStatus = CustomInvoiceStatus(
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
      if (kDebugMode) {
        print(_error);
      }
      notifyListeners();
    }
  }

  // Update an existing status
  Future<void> updateStatus(String id, String label, Color color) async {
    try {
      _error = null;

      await _firestore.collection('customInvoiceStatuses').doc(id).update({
        'label': label,
        'color': color.toARGB32(),
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

      await _firestore.collection('customInvoiceStatuses').doc(id).delete();
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
  CustomInvoiceStatus? getStatusById(String id) {
    for (final status in _statuses) {
      if (status.id == id) {
        return status;
      }
    }
    return null;
  }

  // Get status by label (for backwards compatibility)
  CustomInvoiceStatus? getStatusByLabel(String label) {
    for (final status in _statuses) {
      if (status.label.toLowerCase() == label.toLowerCase()) {
        return status;
      }
    }
    return null;
  }

  // Clear error message
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
