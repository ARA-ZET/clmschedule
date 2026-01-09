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

      if (snapshot.docs.isEmpty) {
        // Initialize with default statuses if none exist
        await initializeDefaultStatuses();
      } else {
        _statuses = snapshot.docs.map((doc) {
          final data = doc.data();
          data['id'] = doc.id; // Ensure the document ID is set
          return CustomInvoiceStatus.fromMap(data);
        }).toList();
      }
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

  // Initialize default invoice statuses
  Future<void> initializeDefaultStatuses() async {
    final defaultStatuses = [
      const CustomInvoiceStatus(
        id: 'pending',
        label: 'Pending',
        color: Colors.orange,
        isDefault: true,
      ),
      const CustomInvoiceStatus(
        id: 'sent',
        label: 'Sent',
        color: Colors.blue,
        isDefault: true,
      ),
      const CustomInvoiceStatus(
        id: 'paid',
        label: 'Paid',
        color: Colors.green,
        isDefault: true,
      ),
      const CustomInvoiceStatus(
        id: 'overdue',
        label: 'Overdue',
        color: Colors.red,
        isDefault: true,
      ),
      const CustomInvoiceStatus(
        id: 'cancelled',
        label: 'Cancelled',
        color: Colors.grey,
        isDefault: true,
      ),
      const CustomInvoiceStatus(
        id: 'partial',
        label: 'Partially Paid',
        color: Colors.teal,
        isDefault: true,
      ),
    ];

    try {
      final batch = _firestore.batch();

      for (final status in defaultStatuses) {
        final docRef =
            _firestore.collection('customInvoiceStatuses').doc(status.id);
        batch.set(docRef, status.toMap());
      }

      await batch.commit();
      _statuses = defaultStatuses;
      notifyListeners();
    } catch (e) {
      _error = 'Error initializing default statuses: $e';
      if (kDebugMode) {
        print(_error);
      }
      notifyListeners();
    }
  }

  // Clear error message
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
