import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/custom_invoice_status.dart';
import '../services/reference_cache_service.dart';

const String _kCollectionName = 'customInvoiceStatuses';

final invoiceStatusRiverpod =
    riverpod.ChangeNotifierProvider<InvoiceStatusProvider>(
        (ref) => InvoiceStatusProvider());

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

      _statuses =
          await ReferenceCacheService.loadCollection<CustomInvoiceStatus>(
        query: _firestore.collection(_kCollectionName).orderBy('label'),
        collectionName: _kCollectionName,
        fromDoc: (doc) {
          final data = Map<String, dynamic>.from(doc.data() as Map);
          data['id'] = doc.id;
          return CustomInvoiceStatus.fromMap(data);
        },
      );
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

      final docRef = await _firestore.collection(_kCollectionName).add({
        'label': label,
        'color': color.toARGB32(),
        'isDefault': false,
      });
      await ReferenceCacheService.bumpVersion(_kCollectionName);

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

      await _firestore.collection(_kCollectionName).doc(id).update({
        'label': label,
        'color': color.toARGB32(),
      });
      await ReferenceCacheService.bumpVersion(_kCollectionName);

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

      await _firestore.collection(_kCollectionName).doc(id).delete();
      await ReferenceCacheService.bumpVersion(_kCollectionName);
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
