import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/schedule_time.dart';

/// One individually-recorded amount a distributor has asked the company to
/// hold on their behalf. Lives at
/// `payrollSavings/{distributorId}/deposits/{id}`.
///
/// Mirrors [Advance]'s structure but in reverse: instead of being paid out
/// upfront and deducted back over time, a deposit is money already withheld
/// that gets paid back out (withdrawn) over time, oldest deposit first.
class SavingsDeposit {
  final String id;
  final double amount;
  final DateTime dateDeposited;

  /// Default withdrawal amount suggested each week while this deposit
  /// still has a balance — the admin can always override it per week.
  final double preferredWithdrawalAmount;
  final String? note;

  /// Running total withdrawn so far, maintained by
  /// `PayrollService.applySavingsWithdrawal`'s FIFO allocation.
  final double amountWithdrawn;

  final DateTime createdAt;

  const SavingsDeposit({
    required this.id,
    required this.amount,
    required this.dateDeposited,
    required this.preferredWithdrawalAmount,
    this.note,
    this.amountWithdrawn = 0,
    required this.createdAt,
  });

  double get balance =>
      (amount - amountWithdrawn) < 0 ? 0 : (amount - amountWithdrawn);

  bool get isSettled => amountWithdrawn >= amount;

  factory SavingsDeposit.fromMap(String id, Map<String, dynamic> data) {
    return SavingsDeposit(
      id: id,
      amount: (data['amount'] as num?)?.toDouble() ?? 0,
      dateDeposited:
          scheduleCivilOrNull((data['dateDeposited'] as Timestamp?)?.toDate()) ??
              scheduleNow(),
      preferredWithdrawalAmount:
          (data['preferredWithdrawalAmount'] as num?)?.toDouble() ?? 0,
      note: data['note'] as String?,
      amountWithdrawn: (data['amountWithdrawn'] as num?)?.toDouble() ?? 0,
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'amount': amount,
        'dateDeposited': Timestamp.fromDate(scheduleCivilToInstant(dateDeposited)),
        'preferredWithdrawalAmount': preferredWithdrawalAmount,
        'note': note,
        'amountWithdrawn': amountWithdrawn,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  SavingsDeposit copyWith({
    double? amount,
    DateTime? dateDeposited,
    double? preferredWithdrawalAmount,
    String? note,
    double? amountWithdrawn,
  }) {
    return SavingsDeposit(
      id: id,
      amount: amount ?? this.amount,
      dateDeposited: dateDeposited ?? this.dateDeposited,
      preferredWithdrawalAmount:
          preferredWithdrawalAmount ?? this.preferredWithdrawalAmount,
      note: note ?? this.note,
      amountWithdrawn: amountWithdrawn ?? this.amountWithdrawn,
      createdAt: createdAt,
    );
  }
}
