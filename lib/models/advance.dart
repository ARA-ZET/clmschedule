import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/schedule_time.dart';

/// What kind of deduction this is — shown on the payslip and in the
/// deductions table so an advance and a penalty (e.g. a lost phone,
/// damages) are never confused with each other.
enum DeductionType {
  advance,
  penalty;

  String get displayName {
    switch (this) {
      case DeductionType.advance:
        return 'Advance';
      case DeductionType.penalty:
        return 'Penalty';
    }
  }

  static DeductionType fromString(String? value) {
    switch (value) {
      case 'penalty':
        return DeductionType.penalty;
      default:
        return DeductionType.advance;
    }
  }
}

/// One individually-recorded deduction owed by a distributor — a cash
/// advance or a penalty (lost phone, damages, etc.). Lives at
/// `payrollAdvances/{distributorId}/advances/{id}`.
///
/// Multiple deductions can be outstanding at once — they're tracked and
/// repaid separately (oldest first), rather than merged into a single
/// rolling balance like the old sheet's ledger.
class Advance {
  final String id;
  final DeductionType type;

  /// Short description, e.g. "Lost cellphone" or "Damage to depot door".
  /// Optional for a plain advance, expected for a penalty.
  final String? label;
  final double amount;
  final DateTime datePaid;

  /// Default deduction amount suggested each week while this item is
  /// still outstanding — the admin can always override it per week.
  final double preferredInstallmentAmount;
  final String? note;

  /// Running total repaid so far, maintained by
  /// `PayrollService.applyAdvanceDeduction`'s FIFO allocation.
  final double amountRepaid;

  final DateTime createdAt;

  const Advance({
    required this.id,
    this.type = DeductionType.advance,
    this.label,
    required this.amount,
    required this.datePaid,
    required this.preferredInstallmentAmount,
    this.note,
    this.amountRepaid = 0,
    required this.createdAt,
  });

  double get balance => (amount - amountRepaid) < 0 ? 0 : (amount - amountRepaid);

  bool get isSettled => amountRepaid >= amount;

  /// Display label for tables/payslips: the custom [label] if set, else
  /// just the type name (e.g. "Advance").
  String get displayLabel =>
      (label != null && label!.trim().isNotEmpty) ? label!.trim() : type.displayName;

  factory Advance.fromMap(String id, Map<String, dynamic> data) {
    return Advance(
      id: id,
      type: DeductionType.fromString(data['type'] as String?),
      label: data['label'] as String?,
      amount: (data['amount'] as num?)?.toDouble() ?? 0,
      datePaid: scheduleCivilOrNull((data['datePaid'] as Timestamp?)?.toDate()) ??
          scheduleNow(),
      preferredInstallmentAmount:
          (data['preferredInstallmentAmount'] as num?)?.toDouble() ?? 0,
      note: data['note'] as String?,
      amountRepaid: (data['amountRepaid'] as num?)?.toDouble() ?? 0,
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'type': type.name,
        'label': label,
        'amount': amount,
        'datePaid': Timestamp.fromDate(scheduleCivilToInstant(datePaid)),
        'preferredInstallmentAmount': preferredInstallmentAmount,
        'note': note,
        'amountRepaid': amountRepaid,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  Advance copyWith({
    DeductionType? type,
    String? label,
    double? amount,
    DateTime? datePaid,
    double? preferredInstallmentAmount,
    String? note,
    double? amountRepaid,
  }) {
    return Advance(
      id: id,
      type: type ?? this.type,
      label: label ?? this.label,
      amount: amount ?? this.amount,
      datePaid: datePaid ?? this.datePaid,
      preferredInstallmentAmount:
          preferredInstallmentAmount ?? this.preferredInstallmentAmount,
      note: note ?? this.note,
      amountRepaid: amountRepaid ?? this.amountRepaid,
      createdAt: createdAt,
    );
  }
}
