import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/payroll_week.dart' as week_util;
import 'payroll_payslip.dart';

/// The Firestore document for one pay week, at
/// `payroll/{yearId}/{monthLabel}/{weekId}`. Holds every distributor's
/// payslip for the week as a map field (see plan for why not a
/// subcollection: small distributor count, both primary reads need every
/// payslip at once, single admin editing at a time).
class PayrollWeek {
  final DateTime weekStart; // Friday
  final DateTime weekEnd; // Thursday
  final DateTime payDate; // Friday after weekEnd

  /// Keyed by distributorId.
  final Map<String, PayrollPayslip> payslips;

  final bool isFinalized;
  final DateTime? finalizedAt;
  final String? finalizedBy;
  final DateTime? updatedAt;
  final String? updatedBy;

  const PayrollWeek({
    required this.weekStart,
    required this.weekEnd,
    required this.payDate,
    this.payslips = const {},
    this.isFinalized = false,
    this.finalizedAt,
    this.finalizedBy,
    this.updatedAt,
    this.updatedBy,
  });

  /// A not-yet-created week (mirrors `DropsheetDay`'s empty-placeholder
  /// pattern) — safe to render before the first save.
  factory PayrollWeek.empty(DateTime anyDateInWeek) {
    final start = week_util.weekStartFor(anyDateInWeek);
    return PayrollWeek(
      weekStart: start,
      weekEnd: week_util.weekEndFor(start),
      payDate: week_util.payDateFor(start),
      payslips: const {},
    );
  }

  factory PayrollWeek.fromMap(String docId, Map<String, dynamic> data) {
    final weekStart = (data['weekStart'] as Timestamp?)?.toDate() ??
        week_util.weekStartFor(DateTime.parse(docId));
    final payslipsRaw = data['payslips'] as Map<String, dynamic>? ?? {};
    return PayrollWeek(
      weekStart: weekStart,
      weekEnd: (data['weekEnd'] as Timestamp?)?.toDate() ??
          week_util.weekEndFor(weekStart),
      payDate: (data['payDate'] as Timestamp?)?.toDate() ??
          week_util.payDateFor(weekStart),
      payslips: payslipsRaw.map((id, v) => MapEntry(
          id, PayrollPayslip.fromMap(id, Map<String, dynamic>.from(v as Map)))),
      isFinalized: data['isFinalized'] as bool? ?? false,
      finalizedAt: (data['finalizedAt'] as Timestamp?)?.toDate(),
      finalizedBy: data['finalizedBy'] as String?,
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      updatedBy: data['updatedBy'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'weekStart': Timestamp.fromDate(weekStart),
        'weekEnd': Timestamp.fromDate(weekEnd),
        'payDate': Timestamp.fromDate(payDate),
        'payslips': payslips.map((id, p) => MapEntry(id, p.toMap())),
        'isFinalized': isFinalized,
        'finalizedAt':
            finalizedAt != null ? Timestamp.fromDate(finalizedAt!) : null,
        'finalizedBy': finalizedBy,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedBy': updatedBy,
      };

  PayrollWeek copyWith({
    Map<String, PayrollPayslip>? payslips,
    bool? isFinalized,
    DateTime? finalizedAt,
    String? finalizedBy,
    String? updatedBy,
  }) {
    return PayrollWeek(
      weekStart: weekStart,
      weekEnd: weekEnd,
      payDate: payDate,
      payslips: payslips ?? this.payslips,
      isFinalized: isFinalized ?? this.isFinalized,
      finalizedAt: finalizedAt ?? this.finalizedAt,
      finalizedBy: finalizedBy ?? this.finalizedBy,
      updatedAt: updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }
}
