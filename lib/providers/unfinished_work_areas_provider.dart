import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/job.dart';
import '../models/custom_polygon.dart';

final unfinishedWorkAreasRiverpod =
    riverpod.ChangeNotifierProvider<UnfinishedWorkAreasProvider>(
  (ref) => UnfinishedWorkAreasProvider(),
);

/// Provider for managing unfinished work areas — jobs not yet assigned
/// to a distributor or date. Stored in Firestore `unfinishedWorkAreas` collection.
class UnfinishedWorkAreasProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  List<Job> _items = [];
  StreamSubscription? _subscription;
  bool _isLoading = false;
  bool _isPanelVisible = false;

  List<Job> get items => _items;
  bool get isLoading => _isLoading;
  bool get isPanelVisible => _isPanelVisible;

  CollectionReference get _collection =>
      _firestore.collection('unfinishedWorkAreas');

  void togglePanel() {
    _isPanelVisible = !_isPanelVisible;
    notifyListeners();
  }

  /// Initialize real-time stream from Firestore.
  Future<void> initialize() async {
    if (_subscription != null) return; // Already listening
    _isLoading = true;
    notifyListeners();

    _subscription = _collection.snapshots().listen(
      (snapshot) {
        debugPrint('UnfinishedWorkAreas stream: ${snapshot.docs.length} docs');
        _items = snapshot.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return _jobFromDoc(doc.id, data);
        }).toList();
        _isLoading = false;
        notifyListeners();
      },
      onError: (e) {
        debugPrint('UnfinishedWorkAreasProvider stream error: $e');
        _isLoading = false;
        notifyListeners();
      },
    );
  }

  /// Create a Job from a Firestore document. Uses a sentinel date and empty
  /// distributorId to indicate "unassigned".
  Job _jobFromDoc(String id, Map<String, dynamic> data) {
    LatLng? dropOffPoint;
    final dropMap = data['dropOffPoint'];
    if (dropMap is Map<String, dynamic>) {
      final lat = (dropMap['latitude'] as num?)?.toDouble();
      final lng = (dropMap['longitude'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        dropOffPoint = LatLng(lat, lng);
      }
    }

    return Job(
      id: id,
      clients: (data['clients'] as List<dynamic>?)?.cast<String>() ?? [],
      workingAreas:
          (data['workingAreas'] as List<dynamic>?)?.cast<String>() ?? [],
      workMaps: (data['workMaps'] as List<dynamic>?)
              ?.map((mapData) =>
                  CustomPolygon.fromMap(mapData as Map<String, dynamic>))
              .toList() ??
          [],
      distributorId: '',
      date: DateTime(1970), // sentinel — not assigned
      statusId: data['statusId'] as String? ?? 'scheduled',
      dropOffPoint: dropOffPoint,
    );
  }

  /// Add a new unfinished work area item.
  Future<String> addItem({
    required List<String> clients,
    required List<String> workingAreas,
    List<CustomPolygon> workMaps = const [],
    String statusId = 'scheduled',
    LatLng? dropOffPoint,
  }) async {
    // Generate a temporary ID for optimistic update
    final tempId = _firestore.collection('dummy').doc().id;

    // Optimistic local update — show item in UI before Firestore confirms
    final optimisticJob = Job(
      id: tempId,
      clients: List<String>.from(clients),
      workingAreas: List<String>.from(workingAreas),
      workMaps: List<CustomPolygon>.from(workMaps),
      distributorId: '',
      date: DateTime(1970),
      statusId: statusId,
      dropOffPoint: dropOffPoint,
    );
    _items = [..._items, optimisticJob];
    notifyListeners();

    try {
      final docRef = await _collection.add({
        'clients': clients,
        'workingAreas': workingAreas,
        'workMaps': workMaps.map((wm) => wm.toMap()).toList(),
        'statusId': statusId,
        if (dropOffPoint != null)
          'dropOffPoint': {
            'latitude': dropOffPoint.latitude,
            'longitude': dropOffPoint.longitude,
          },
        'createdAt': FieldValue.serverTimestamp(),
      });
      debugPrint('UnfinishedWorkAreas: added doc ${docRef.id}');

      // Replace temp ID with real Firestore ID in local list
      _items = _items.map((item) {
        if (item.id == tempId) {
          return Job(
            id: docRef.id,
            clients: item.clients,
            workingAreas: item.workingAreas,
            workMaps: item.workMaps,
            distributorId: item.distributorId,
            date: item.date,
            statusId: item.statusId,
            dropOffPoint: item.dropOffPoint,
          );
        }
        return item;
      }).toList();
      notifyListeners();

      return docRef.id;
    } catch (e) {
      debugPrint('UnfinishedWorkAreas: add failed: $e');
      // Rollback optimistic update
      _items = _items.where((item) => item.id != tempId).toList();
      notifyListeners();
      rethrow;
    }
  }

  /// Add a scheduled job back to the unfinished pool (drag from grid → panel).
  Future<String> addFromJob(Job job) async {
    return addItem(
      clients: job.clients,
      workingAreas: job.workingAreas,
      workMaps: job.workMaps,
      statusId: job.statusId,
      dropOffPoint: job.dropOffPoint,
    );
  }

  /// Remove an item by id (when it gets assigned to the schedule grid).
  Future<void> removeItem(String id) async {
    // Optimistic local removal
    final removed = _items.where((item) => item.id == id).toList();
    _items = _items.where((item) => item.id != id).toList();
    notifyListeners();

    try {
      await _collection.doc(id).delete();
      debugPrint('UnfinishedWorkAreas: removed doc $id');
    } catch (e) {
      debugPrint('UnfinishedWorkAreas: remove failed: $e');
      // Rollback — re-add removed items
      _items = [..._items, ...removed];
      notifyListeners();
      rethrow;
    }
  }

  /// Update an existing item.
  Future<void> updateItem(
    String id, {
    List<String>? clients,
    List<String>? workingAreas,
    String? statusId,
  }) async {
    final updates = <String, dynamic>{};
    if (clients != null) updates['clients'] = clients;
    if (workingAreas != null) updates['workingAreas'] = workingAreas;
    if (statusId != null) updates['statusId'] = statusId;
    if (updates.isNotEmpty) {
      await _collection.doc(id).update(updates);
    }
  }

  /// Replace the `workMaps` list for an existing item. Used when the shareable
  /// map editor edits polygons that originated from an unfinished work area
  /// so the edits flow back to Firestore.
  Future<void> updateItemWorkMaps(
      String id, List<CustomPolygon> workMaps) async {
    // Optimistic local update so the UI reflects changes immediately.
    _items = _items.map((item) {
      if (item.id == id) {
        return Job(
          id: item.id,
          clients: item.clients,
          workingAreas: item.workingAreas,
          workMaps: List<CustomPolygon>.from(workMaps),
          distributorId: item.distributorId,
          date: item.date,
          statusId: item.statusId,
          dropOffPoint: item.dropOffPoint,
        );
      }
      return item;
    }).toList();
    notifyListeners();

    try {
      await _collection.doc(id).update({
        'workMaps': workMaps.map((wm) => wm.toMap()).toList(),
      });
      debugPrint('UnfinishedWorkAreas: updated workMaps for $id '
          '(${workMaps.length} elements)');
    } catch (e) {
      debugPrint('UnfinishedWorkAreas: updateItemWorkMaps failed: $e');
      rethrow;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
