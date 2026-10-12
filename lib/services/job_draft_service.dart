import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

/// An unfinished Add Job form, kept so it can be picked up later.
///
/// Stored in Firestore under the user's own preferences rather than locally:
/// this codebase skips Hive on web, and the app ships a web build, so a local
/// draft would silently never persist for most users. Firestore also means the
/// draft survives a closed tab and follows the user to another machine.
///
/// One draft per user. Adding a job is something you do once at a time, and a
/// list of half-finished jobs would be a worse problem than the one this solves.
class JobDraftService {
  JobDraftService(this._firestore, this._auth);

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  String? get _uid => _auth.currentUser?.uid;

  DocumentReference<Map<String, dynamic>>? get _doc {
    final uid = _uid;
    if (uid == null) return null;
    return _firestore
        .collection('userPreferences')
        .doc(uid)
        .collection('jobList')
        .doc('draft');
  }

  /// Save [fields] as the current draft.
  ///
  /// Never throws: losing a draft is a disappointment, but failing the action
  /// the user actually pressed — closing the dialog — would be worse.
  Future<bool> save(Map<String, dynamic> fields) async {
    final doc = _doc;
    if (doc == null) return false;

    try {
      await doc.set({
        ...fields,
        'savedAt': Timestamp.fromDate(DateTime.now()),
      });
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('JobDraftService.save failed: $e');
      return false;
    }
  }

  /// The stored draft, or null when there is none.
  ///
  /// Drafts older than [maxAge] are ignored and cleaned up: a half-typed job
  /// from three weeks ago is far more likely to confuse than to help, and
  /// offering to restore one invites saving something long since superseded.
  Future<Map<String, dynamic>?> load({
    Duration maxAge = const Duration(days: 7),
  }) async {
    final doc = _doc;
    if (doc == null) return null;

    try {
      final snap = await doc.get();
      if (!snap.exists || snap.data() == null) return null;

      final data = Map<String, dynamic>.from(snap.data()!);
      final savedAt = (data['savedAt'] as Timestamp?)?.toDate();
      if (savedAt == null || DateTime.now().difference(savedAt) > maxAge) {
        await clear();
        return null;
      }
      return data;
    } catch (e) {
      if (kDebugMode) debugPrint('JobDraftService.load failed: $e');
      return null;
    }
  }

  Future<void> clear() async {
    try {
      await _doc?.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('JobDraftService.clear failed: $e');
    }
  }
}

final jobDraftServiceRiverpod = riverpod.Provider<JobDraftService>(
  (ref) => JobDraftService(FirebaseFirestore.instance, FirebaseAuth.instance),
);
