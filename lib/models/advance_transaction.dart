import 'package:cloud_firestore/cloud_firestore.dart';

/// A single entry in a distributor's advance history, at
/// `payrollAdvances/{distributorId}/transactions/{id}`. History is never
/// deleted or edited — reversals are posted as new offsetting entries so
/// the full audit trail stays intact.
enum AdvanceTransactionType {
  grant,
  deduction,
  adjustment;

  static AdvanceTransactionType fromString(String? value) {
    switch (value) {
      case 'deduction':
        return AdvanceTransactionType.deduction;
      case 'adjustment':
        return AdvanceTransactionType.adjustment;
      default:
        return AdvanceTransactionType.grant;
    }
  }
}

class AdvanceTransaction {
  final String id;
  final AdvanceTransactionType type;

  /// Signed: positive for a grant or an upward adjustment, negative for a
  /// deduction or a downward/reversing adjustment. `balance = sum(amount)`.
  final double amount;
  final DateTime date;
  final String? note;

  /// `weekIdFor(weekStart)` of the payroll week that triggered this
  /// transaction, when `type == deduction` — lets `syncAdvanceDeduction`
  /// find and reconcile against a prior post for the same week.
  final String? linkedWeekId;
  final String? createdBy;
  final DateTime createdAt;

  const AdvanceTransaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.date,
    this.note,
    this.linkedWeekId,
    this.createdBy,
    required this.createdAt,
  });

  factory AdvanceTransaction.fromMap(String id, Map<String, dynamic> data) {
    return AdvanceTransaction(
      id: id,
      type: AdvanceTransactionType.fromString(data['type'] as String?),
      amount: (data['amount'] as num?)?.toDouble() ?? 0,
      date: (data['date'] as Timestamp?)?.toDate() ?? DateTime.now(),
      note: data['note'] as String?,
      linkedWeekId: data['linkedWeekId'] as String?,
      createdBy: data['createdBy'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'type': type.name,
        'amount': amount,
        'date': Timestamp.fromDate(date),
        'note': note,
        'linkedWeekId': linkedWeekId,
        'createdBy': createdBy,
        'createdAt': Timestamp.fromDate(createdAt),
      };
}
