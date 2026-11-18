import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/custom_job_list_status.dart';
import '../services/reference_cache_service.dart';
import '../recycle_bin/recycle_bin_entry.dart';
import '../recycle_bin/recycle_bin_writer.dart';

const String _kCollectionName = 'customJobListStatuses';

final jobListStatusRiverpod =
    riverpod.ChangeNotifierProvider<JobListStatusProvider>(
        (ref) => JobListStatusProvider());

class JobListStatusProvider extends ChangeNotifier {
  /// Latest instance, so the Job List search can show status labels
  /// without threading the provider through (same pattern as
  /// JobTypeProvider.instance).
  static JobListStatusProvider? _instance;
  static JobListStatusProvider? get instance => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<CustomJobListStatus> _statuses = [];
  bool _isLoading = false;
  String? _error;

  List<CustomJobListStatus> get statuses => List.unmodifiable(_statuses);
  bool get isLoading => _isLoading;
  String? get error => _error;

  JobListStatusProvider() {
    _instance = this;
    loadStatuses();
  }

  // Load statuses from Firestore
  Future<void> loadStatuses() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      _statuses =
          await ReferenceCacheService.loadCollection<CustomJobListStatus>(
        query: _firestore.collection(_kCollectionName).orderBy('label'),
        collectionName: _kCollectionName,
        fromDoc: (doc) {
          final data = Map<String, dynamic>.from(doc.data() as Map);
          data['id'] = doc.id;
          return CustomJobListStatus.fromMap(data);
        },
        onCached: (cached) {
          _statuses = cached;
          _isLoading = false;
          notifyListeners();
        },
      );
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

      final docRef = await _firestore.collection(_kCollectionName).add({
        'label': label,
        'color': color.toARGB32(),
        'isDefault': false,
        'hiddenForJobTypes': hiddenForJobTypes,
      });
      await ReferenceCacheService.bumpVersion(_kCollectionName);

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

      await _firestore.collection(_kCollectionName).doc(id).update(updateData);
      await ReferenceCacheService.bumpVersion(_kCollectionName);

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

      await RecycleBinWriter(_firestore).moveDocToBin(
        _firestore.collection(_kCollectionName).doc(id),
        type: RecycleBinType.jobListStatus,
        label: (d) => binLabel(d, 'job list status'),
      );
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
