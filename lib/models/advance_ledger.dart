import 'package:cloud_firestore/cloud_firestore.dart';

/// Rollup doc at `payrollAdvances/{distributorId}`: the running advance
/// balance for one distributor. Always recomputed server-side inside a
/// transaction alongside a new `AdvanceTransaction` — never hand-edited.
class AdvanceLedger {
  final String distributorId;
  final double totalAdvanced;
  final double totalRepaid;
  final double balance; // totalAdvanced - totalRepaid
  final DateTime? updatedAt;

  const AdvanceLedger({
    required this.distributorId,
    required this.totalAdvanced,
    required this.totalRepaid,
    required this.balance,
    this.updatedAt,
  });

  factory AdvanceLedger.empty(String distributorId) => AdvanceLedger(
        distributorId: distributorId,
        totalAdvanced: 0,
        totalRepaid: 0,
        balance: 0,
      );

  factory AdvanceLedger.fromMap(String distributorId, Map<String, dynamic> data) {
    return AdvanceLedger(
      distributorId: distributorId,
      totalAdvanced: (data['totalAdvanced'] as num?)?.toDouble() ?? 0,
      totalRepaid: (data['totalRepaid'] as num?)?.toDouble() ?? 0,
      balance: (data['balance'] as num?)?.toDouble() ?? 0,
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'totalAdvanced': totalAdvanced,
        'totalRepaid': totalRepaid,
        'balance': balance,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      };
}
