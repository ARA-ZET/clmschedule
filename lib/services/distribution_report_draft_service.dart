// services/distribution_report_draft_service.dart
//
// Saved progress on distribution reports, one doc per Job List job at
// distributionReportDrafts/{jobId}. Must stay listed in firestore.rules —
// the fail-closed default would make every save fail.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/distribution_report_draft.dart';

const String _kCollection = 'distributionReportDrafts';

final distributionReportDraftServiceRiverpod =
    riverpod.Provider<DistributionReportDraftService>(
        (ref) => DistributionReportDraftService());

/// Job ids that have a saved report draft — the Job List marks their report
/// button so a half-written report can be found again.
final distributionReportDraftIdsRiverpod =
    riverpod.StreamProvider<Set<String>>((ref) {
  return ref.watch(distributionReportDraftServiceRiverpod).watchJobIds();
});

class DistributionReportDraftService {
  final FirebaseFirestore? _injected;

  DistributionReportDraftService({FirebaseFirestore? firestore})
      : _injected = firestore;

  CollectionReference<Map<String, dynamic>> get _drafts =>
      (_injected ?? FirebaseFirestore.instance).collection(_kCollection);

  Future<DistributionReportDraft?> load(String jobId) async {
    final doc = await _drafts.doc(jobId).get();
    final data = doc.data();
    return data == null ? null : DistributionReportDraft.fromMap(jobId, data);
  }

  Future<void> save(DistributionReportDraft draft) {
    return _drafts.doc(draft.jobId).set({
      ...draft.toContentMap(),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': FirebaseAuth.instance.currentUser?.email ?? '',
    });
  }

  Future<void> delete(String jobId) => _drafts.doc(jobId).delete();

  /// Ids only; the drafts are small but there is no need to ship them all to
  /// every Job List.
  Stream<Set<String>> watchJobIds() => _drafts
      .snapshots()
      .map((snap) => {for (final d in snap.docs) d.id});
}
