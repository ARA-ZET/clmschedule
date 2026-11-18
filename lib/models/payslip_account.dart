import 'package:cloud_firestore/cloud_firestore.dart';

/// Where a distributor's payslip sign-up stands.
enum PayslipAccountStatus {
  pending,
  approved,
  rejected,
  removed;

  static PayslipAccountStatus fromString(String? value) =>
      PayslipAccountStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => PayslipAccountStatus.pending,
      );
}

/// A distributor's sign-up on clmworking.web.app/payslips.html, at
/// `payslipAccounts/{id}`.
///
/// Created only by the `payslipPortal` Cloud Function. An admin approves it
/// by linking it to a [distributorId]: that link is the only thing deciding
/// whose paid payslips the phone sees. The password and sessions are kept
/// where no app can read them (see functions/lib/payslip_portal.js).
class PayslipAccount {
  final String id;
  final String name;

  /// Normalised `0XXXXXXXXX` — the distributor's login.
  final String phone;

  /// Four digits shown on the distributor's phone after signing up. The
  /// office asks for it before approving, so a request someone else made
  /// with this phone number is not approved by mistake.
  final String signupCode;

  final PayslipAccountStatus status;

  /// The distributor they picked from the legal-name list when signing up.
  /// Only a claim: the office checks the code and sets [distributorId].
  final String? claimedDistributorId;

  final String? distributorId;
  final String? distributorName;
  final DateTime? createdAt;
  final DateTime? reviewedAt;
  final String? reviewedBy;
  final DateTime? lastLoginAt;

  const PayslipAccount({
    required this.id,
    required this.name,
    required this.phone,
    required this.signupCode,
    required this.status,
    this.claimedDistributorId,
    this.distributorId,
    this.distributorName,
    this.createdAt,
    this.reviewedAt,
    this.reviewedBy,
    this.lastLoginAt,
  });

  factory PayslipAccount.fromMap(String id, Map<String, dynamic> data) {
    DateTime? time(String key) => (data[key] as Timestamp?)?.toDate();
    return PayslipAccount(
      id: id,
      name: data['name'] as String? ?? '',
      phone: data['phone'] as String? ?? '',
      signupCode: data['signupCode'] as String? ?? '',
      status: PayslipAccountStatus.fromString(data['status'] as String?),
      claimedDistributorId: data['claimedDistributorId'] as String?,
      distributorId: data['distributorId'] as String?,
      distributorName: data['distributorName'] as String?,
      createdAt: time('createdAt'),
      reviewedAt: time('reviewedAt'),
      reviewedBy: data['reviewedBy'] as String?,
      lastLoginAt: time('lastLoginAt'),
    );
  }

  /// `082 123 4567`.
  String get phoneDisplay => phone.length == 10
      ? '${phone.substring(0, 3)} ${phone.substring(3, 6)} ${phone.substring(6)}'
      : phone;
}

/// Digits only, with a +27/27 prefix turned into a leading 0 — the same rule
/// as `normalizePhone` in functions/lib/payslip_portal.js, so a distributor
/// profile's `phone1`/`phone2` can be matched to a sign-up's phone.
String? normalizeSaPhone(String? raw) {
  var digits = (raw ?? '').replaceAll(RegExp(r'\D+'), '');
  if (digits.startsWith('27') && digits.length == 11) {
    digits = '0${digits.substring(2)}';
  }
  if (digits.length == 9 && !digits.startsWith('0')) digits = '0$digits';
  return RegExp(r'^0\d{9}$').hasMatch(digits) ? digits : null;
}
