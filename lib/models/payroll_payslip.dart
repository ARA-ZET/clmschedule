import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/payroll_week.dart';
import 'distributor_payroll_profile.dart';
import 'payroll_daily_entry.dart';
import 'payroll_settings.dart';

/// One distributor's payslip for one payroll week. Lives in
/// `PayrollWeek.payslips`, keyed by distributor id.
///
/// The `*Snapshot` fields are captured at each recompute so later edits to
/// `PayrollSettings` or a distributor's profile never retroactively rewrite
/// an already-computed week's numbers.
class PayrollPayslip {
  final String distributorId;
  final String distributorName;

  final double dayRateSnapshot;
  final Map<String, double> bonusCodeAmountsSnapshot;
  final double perSetRateSnapshot;
  final double estimateBonusSnapshot;
  final bool transportEligibleSnapshot;
  final double transportFareSnapshot;
  final String? bankNameSnapshot;
  final String? bankAccountHolderSnapshot;
  final String? bankAccountNumberSnapshot;
  final String? bankBranchCodeSnapshot;
  final String paymentMethodSnapshot;

  /// Keyed by `dayKeyFor(date)`, one entry per day Fri..Thu.
  final Map<String, PayrollDailyEntry> dailyEntries;

  final int transportTrips;
  final double transportDeduction;

  final bool isDeductingAdvanceThisWeek;
  final double advanceDeductionAmount;
  final String advanceDeductionNote;

  /// Internal bookkeeping: has [advanceDeductionAmount] already been posted
  /// to the distributor's `AdvanceLedger`? Prevents double-posting when a
  /// payslip is re-saved for an unrelated edit.
  final bool advanceAppliedToLedger;

  final double grossWage;
  final double netWage;

  final DateTime? updatedAt;
  final String? updatedBy;

  const PayrollPayslip({
    required this.distributorId,
    required this.distributorName,
    required this.dayRateSnapshot,
    required this.bonusCodeAmountsSnapshot,
    required this.perSetRateSnapshot,
    required this.estimateBonusSnapshot,
    required this.transportEligibleSnapshot,
    required this.transportFareSnapshot,
    this.bankNameSnapshot,
    this.bankAccountHolderSnapshot,
    this.bankAccountNumberSnapshot,
    this.bankBranchCodeSnapshot,
    this.paymentMethodSnapshot = 'EFT',
    this.dailyEntries = const {},
    this.transportTrips = 0,
    this.transportDeduction = 0,
    this.isDeductingAdvanceThisWeek = false,
    this.advanceDeductionAmount = 0,
    this.advanceDeductionNote = '',
    this.advanceAppliedToLedger = false,
    this.grossWage = 0,
    this.netWage = 0,
    this.updatedAt,
    this.updatedBy,
  });

  /// A brand-new payslip for [weekStart], with a blank day for each of the
  /// 7 days and rates snapshotted from the distributor's current profile
  /// (merged over company [settings]).
  factory PayrollPayslip.blank({
    required String distributorId,
    required String distributorName,
    required DateTime weekStart,
    required PayrollSettings settings,
    required DistributorPayrollProfile profile,
  }) {
    final days = daysInWeek(weekStart);
    return PayrollPayslip(
      distributorId: distributorId,
      distributorName: distributorName,
      dayRateSnapshot: profile.resolvedDayRate(settings),
      bonusCodeAmountsSnapshot: profile.resolvedBonusCodeAmounts(settings),
      perSetRateSnapshot: profile.resolvedPerSetRate(settings),
      estimateBonusSnapshot: profile.resolvedEstimateBonus(settings),
      transportEligibleSnapshot: profile.transportEligible,
      transportFareSnapshot: profile.resolvedTransportFarePerTrip(settings),
      bankNameSnapshot: profile.bankName,
      bankAccountHolderSnapshot: profile.bankAccountHolder,
      bankAccountNumberSnapshot: profile.bankAccountNumber,
      bankBranchCodeSnapshot: profile.bankBranchCode,
      paymentMethodSnapshot: profile.paymentMethod,
      dailyEntries: {
        for (final d in days) dayKeyFor(d): PayrollDailyEntry.empty(d),
      },
    );
  }

  factory PayrollPayslip.fromMap(String distributorId, Map<String, dynamic> data) {
    final entries = <String, PayrollDailyEntry>{};
    final rawEntries = data['dailyEntries'] as Map<String, dynamic>? ?? {};
    for (final e in rawEntries.entries) {
      final parts = e.key.split('-');
      final date = DateTime(
        int.tryParse(parts[0]) ?? DateTime.now().year,
        int.tryParse(parts[1]) ?? 1,
        int.tryParse(parts[2]) ?? 1,
      );
      entries[e.key] =
          PayrollDailyEntry.fromMap(date, Map<String, dynamic>.from(e.value as Map));
    }
    return PayrollPayslip(
      distributorId: distributorId,
      distributorName: data['distributorName'] as String? ?? '',
      dayRateSnapshot: (data['dayRateSnapshot'] as num?)?.toDouble() ?? 0,
      bonusCodeAmountsSnapshot: (data['bonusCodeAmountsSnapshot']
                  as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, (v as num).toDouble())) ??
          const {},
      perSetRateSnapshot: (data['perSetRateSnapshot'] as num?)?.toDouble() ?? 0,
      estimateBonusSnapshot:
          (data['estimateBonusSnapshot'] as num?)?.toDouble() ?? 0,
      transportEligibleSnapshot:
          data['transportEligibleSnapshot'] as bool? ?? false,
      transportFareSnapshot:
          (data['transportFareSnapshot'] as num?)?.toDouble() ?? 0,
      bankNameSnapshot: data['bankNameSnapshot'] as String?,
      bankAccountHolderSnapshot: data['bankAccountHolderSnapshot'] as String?,
      bankAccountNumberSnapshot: data['bankAccountNumberSnapshot'] as String?,
      bankBranchCodeSnapshot: data['bankBranchCodeSnapshot'] as String?,
      paymentMethodSnapshot: data['paymentMethodSnapshot'] as String? ?? 'EFT',
      dailyEntries: entries,
      transportTrips: (data['transportTrips'] as num?)?.toInt() ?? 0,
      transportDeduction: (data['transportDeduction'] as num?)?.toDouble() ?? 0,
      isDeductingAdvanceThisWeek:
          data['isDeductingAdvanceThisWeek'] as bool? ?? false,
      advanceDeductionAmount:
          (data['advanceDeductionAmount'] as num?)?.toDouble() ?? 0,
      advanceDeductionNote: data['advanceDeductionNote'] as String? ?? '',
      advanceAppliedToLedger: data['advanceAppliedToLedger'] as bool? ?? false,
      grossWage: (data['grossWage'] as num?)?.toDouble() ?? 0,
      netWage: (data['netWage'] as num?)?.toDouble() ?? 0,
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      updatedBy: data['updatedBy'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'distributorName': distributorName,
        'dayRateSnapshot': dayRateSnapshot,
        'bonusCodeAmountsSnapshot': bonusCodeAmountsSnapshot,
        'perSetRateSnapshot': perSetRateSnapshot,
        'estimateBonusSnapshot': estimateBonusSnapshot,
        'transportEligibleSnapshot': transportEligibleSnapshot,
        'transportFareSnapshot': transportFareSnapshot,
        'bankNameSnapshot': bankNameSnapshot,
        'bankAccountHolderSnapshot': bankAccountHolderSnapshot,
        'bankAccountNumberSnapshot': bankAccountNumberSnapshot,
        'bankBranchCodeSnapshot': bankBranchCodeSnapshot,
        'paymentMethodSnapshot': paymentMethodSnapshot,
        'dailyEntries':
            dailyEntries.map((k, v) => MapEntry(k, v.toMap())),
        'transportTrips': transportTrips,
        'transportDeduction': transportDeduction,
        'isDeductingAdvanceThisWeek': isDeductingAdvanceThisWeek,
        'advanceDeductionAmount': advanceDeductionAmount,
        'advanceDeductionNote': advanceDeductionNote,
        'advanceAppliedToLedger': advanceAppliedToLedger,
        'grossWage': grossWage,
        'netWage': netWage,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedBy': updatedBy,
      };

  PayrollPayslip copyWith({
    Map<String, double>? bonusCodeAmountsSnapshot,
    Map<String, PayrollDailyEntry>? dailyEntries,
    int? transportTrips,
    double? transportDeduction,
    bool? isDeductingAdvanceThisWeek,
    double? advanceDeductionAmount,
    String? advanceDeductionNote,
    bool? advanceAppliedToLedger,
    double? grossWage,
    double? netWage,
    String? updatedBy,
  }) {
    return PayrollPayslip(
      distributorId: distributorId,
      distributorName: distributorName,
      dayRateSnapshot: dayRateSnapshot,
      bonusCodeAmountsSnapshot:
          bonusCodeAmountsSnapshot ?? this.bonusCodeAmountsSnapshot,
      perSetRateSnapshot: perSetRateSnapshot,
      estimateBonusSnapshot: estimateBonusSnapshot,
      transportEligibleSnapshot: transportEligibleSnapshot,
      transportFareSnapshot: transportFareSnapshot,
      bankNameSnapshot: bankNameSnapshot,
      bankAccountHolderSnapshot: bankAccountHolderSnapshot,
      bankAccountNumberSnapshot: bankAccountNumberSnapshot,
      bankBranchCodeSnapshot: bankBranchCodeSnapshot,
      paymentMethodSnapshot: paymentMethodSnapshot,
      dailyEntries: dailyEntries ?? this.dailyEntries,
      transportTrips: transportTrips ?? this.transportTrips,
      transportDeduction: transportDeduction ?? this.transportDeduction,
      isDeductingAdvanceThisWeek:
          isDeductingAdvanceThisWeek ?? this.isDeductingAdvanceThisWeek,
      advanceDeductionAmount:
          advanceDeductionAmount ?? this.advanceDeductionAmount,
      advanceDeductionNote:
          advanceDeductionNote ?? this.advanceDeductionNote,
      advanceAppliedToLedger:
          advanceAppliedToLedger ?? this.advanceAppliedToLedger,
      grossWage: grossWage ?? this.grossWage,
      netWage: netWage ?? this.netWage,
      updatedAt: updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }
}
