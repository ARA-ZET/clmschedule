import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/distributor.dart';
import '../models/payslip_account.dart';

/// The office's side of distributor payslip access: the list of sign-ups
/// from clmworking.web.app/payslips.html and the admin's decisions on them.
///
/// Firestore rules let only admins read `payslipAccounts`, and only the
/// review fields (status, linked distributor, who/when) may be written —
/// the sign-ups themselves are created by the `payslipPortal` function.
class PayslipAccessService {
  final FirebaseFirestore _db;

  PayslipAccessService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _accounts =>
      _db.collection('payslipAccounts');

  /// Every sign-up, newest first. The collection stays small (one per
  /// distributor plus the odd re-sign-up), so it is read whole.
  Stream<List<PayslipAccount>> streamAccounts() =>
      _accounts.snapshots().map((snap) {
        final list = snap.docs
            .map((d) => PayslipAccount.fromMap(d.id, d.data()))
            .toList()
          ..sort((a, b) => (b.createdAt ?? DateTime(9999))
              .compareTo(a.createdAt ?? DateTime(9999)));
        return list;
      });

  Future<void> _review(
    String accountId,
    PayslipAccountStatus status,
    String reviewer, {
    Map<String, dynamic> extra = const {},
  }) {
    return _accounts.doc(accountId).update({
      'status': status.name,
      ...extra,
      'reviewedAt': FieldValue.serverTimestamp(),
      'reviewedBy': reviewer,
    });
  }

  /// Lets this sign-up see [distributor]'s paid payslips.
  Future<void> approve(
          String accountId, Distributor distributor, String reviewer) =>
      _review(accountId, PayslipAccountStatus.approved, reviewer, extra: {
        'distributorId': distributor.id,
        'distributorName': distributor.name,
      });

  Future<void> reject(String accountId, String reviewer) =>
      _review(accountId, PayslipAccountStatus.rejected, reviewer);

  /// Cuts the phone off on its next request. The distributor can sign up
  /// again with the same number (how a forgotten password is reset), which
  /// needs a fresh approval.
  Future<void> remove(String accountId, String reviewer) =>
      _review(accountId, PayslipAccountStatus.removed, reviewer);

  /// Undo for [reject] / [remove]: puts the account back as it was.
  Future<void> restore(PayslipAccount before, String reviewer) =>
      _review(before.id, before.status, reviewer);
}
