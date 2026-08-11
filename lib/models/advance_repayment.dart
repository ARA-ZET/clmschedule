import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/schedule_time.dart';

/// One repayment installment applied against a specific [Advance]. Lives at
/// `payrollAdvances/{distributorId}/repayments/{id}`.
///
/// Kept as permanent history (even across edits to the same pay week, which
/// reverse and re-post their own week's entry) so a distributor's full
/// repayment history can always be reconstructed and shown as a table.
class AdvanceRepayment {
  final String id;
  final String advanceId;
  final double amount;
  final DateTime date;

  /// The payroll week id (`weekIdFor(weekStart)`) this repayment was
  /// deducted in, if any — lets `applyAdvanceDeduction` find and reconcile
  /// the repayment(s) tied to a given week being re-saved.
  final String? linkedWeekId;
  final String? note;
  final DateTime createdAt;

  const AdvanceRepayment({
    required this.id,
    required this.advanceId,
    required this.amount,
    required this.date,
    this.linkedWeekId,
    this.note,
    required this.createdAt,
  });

  factory AdvanceRepayment.fromMap(String id, Map<String, dynamic> data) {
    return AdvanceRepayment(
      id: id,
      advanceId: data['advanceId'] as String? ?? '',
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
        'advanceId': advanceId,
        'amount': amount,
        'date': Timestamp.fromDate(scheduleCivilToInstant(date)),
        'linkedWeekId': linkedWeekId,
        'note': note,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}
