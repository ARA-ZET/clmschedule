import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../models/driver_issue.dart';
import 'vehicle_inspection_service.dart';

/// Reads the issues drivers report from clmgpx and records the office's
/// resolution. The phone creates each doc once; the office only ever writes
/// the `status` field (or deletes the report).
class DriverIssueService {
  DriverIssueService({FirebaseFirestore? firestore, FirebaseStorage? storage})
      : _db = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;

  CollectionReference<Map<String, dynamic>> get _issues =>
      _db.collection('driverIssues');

  /// Live issues dated [fromCivil] or later.
  Stream<List<DriverIssue>> streamSince(DateTime fromCivil) => _issues
      .where('date',
          isGreaterThanOrEqualTo: VehicleInspectionService.dateKey(fromCivil))
      .snapshots()
      .map((s) => s.docs.map(DriverIssue.fromFirestore).toList());

  Future<void> setResolved(String id,
      {required bool resolved, String comment = ''}) {
    return _issues.doc(id).update({
      'status': resolved
          ? {
              'state': 'resolved',
              'by': _staffName(),
              'at': FieldValue.serverTimestamp(),
              'comment': comment.trim(),
            }
          : {'state': 'open'},
    });
  }

  final Map<String, Future<String?>> _urlCache = {};

  /// Download URL for a photo, or null when it no longer exists.
  Future<String?> photoUrl(String path) => _urlCache.putIfAbsent(path, () async {
        try {
          return await _storage.ref(path).getDownloadURL();
        } on FirebaseException catch (e) {
          if (e.code == 'object-not-found') return null;
          _urlCache.remove(path);
          rethrow;
        }
      });

  static String _staffName() {
    final user = FirebaseAuth.instance.currentUser;
    return user?.displayName?.isNotEmpty == true
        ? user!.displayName!
        : (user?.email ?? '');
  }
}
