import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/schedule_time.dart';

/// One withdrawal installment paid out against a specific [SavingsDeposit].
/// Lives at `payrollSavings/{distributorId}/withdrawals/{id}`.
///
/// Kept as permanent history (even across edits to the same pay week, which
/// reverse and re-post their own week's entry) so a distributor's full
/// savings withdrawal history can always be reconstructed and shown as a
/// table.
class SavingsWithdrawal {
  final String id;
  final String depositId;
  final double amount;
  final DateTime date;

  /// The payroll week id (`weekIdFor(weekStart)`) this withdrawal was paid
  /// out in, if any — lets `applySavingsWithdrawal` find and reconcile the
  /// withdrawal(s) tied to a given week being re-saved.
  final String? linkedWeekId;
  final String? note;
  final DateTime createdAt;

  const SavingsWithdrawal({
    required this.id,
    required this.depositId,
    required this.amount,
    required this.date,
    this.linkedWeekId,
    this.note,
    required this.createdAt,
  });

  factory SavingsWithdrawal.fromMap(String id, Map<String, dynamic> data) {
    return SavingsWithdrawal(
      id: id,
      depositId: data['depositId'] as String? ?? '',
      amount: (data['amount'] as num?)?.toDouble() ?? 0,
      date: scheduleCivilOrNull((data['date'] as Timestamp?)?.toDate()) ??
          scheduleNow(),
      linkedWeekId: data['linkedWeekId'] as String?,
      note: data['note'] as String?,
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'depositId': depositId,
        'amount': amount,
        'date': Timestamp.fromDate(scheduleCivilToInstant(date)),
        'linkedWeekId': linkedWeekId,
        'note': note,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}
