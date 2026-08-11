import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/payroll_week.dart';
import 'distributor_payroll_profile.dart';
import 'payment_account.dart';
import 'payment_status.dart';
import 'payroll_daily_entry.dart';
import 'payroll_settings.dart';

/// One distributor's payslip for one payroll week. Lives in
/// `PayrollWeek.payslips`, keyed by distributor id.
///
/// The `*Snapshot` fields (including [paymentAccountSnapshot]) are captured
/// at each recompute so later edits to `PayrollSettings` or a distributor's
/// profile never retroactively rewrite an already-computed week's numbers.
class PayrollPayslip {
  final String distributorId;
  final String distributorName;

  final double dayRateSnapshot;
  final Map<String, double> bonusCodeAmountsSnapshot;
  final double perSetRateSnapshot;
  final double estimateBonusSnapshot;

  /// Which of the distributor's saved `paymentAccounts` this week was paid
  /// through — lets the Banking tab pre-select the right one and detect
  /// when it no longer exists in the distributor's current profile.
  final String? selectedPaymentAccountId;

  /// Frozen copy of the selected account's details at the time this week
  /// was paid — a distributor's saved accounts can change (a number
  /// updated, an account removed) without rewriting historical payslips.
  final PaymentAccount? paymentAccountSnapshot;

  /// Whether this week's payment has gone out yet — recorded from the
  /// Banking tab, defaults to [PaymentStatus.notPaid].
  final PaymentStatus paymentStatus;

  /// Free-text note on this week's payment (e.g. "sent late", "verify ref").
  final String paymentNotes;

  /// Keyed by `dayKeyFor(date)`, one entry per day Fri..Thu.
  final Map<String, PayrollDailyEntry> dailyEntries;

  final bool isDeductingAdvanceThisWeek;
  final double advanceDeductionAmount;
  final String advanceDeductionNote;

  /// Internal bookkeeping: has [advanceDeductionAmount] already been posted
  /// against the distributor's outstanding advances? `applyAdvanceDeduction`
  /// reconciles by `linkedWeekId` regardless, so this is informational only.
  final bool advanceAppliedToLedger;

  /// True once an admin has explicitly set this week's advance deduction via
  /// the payslip's Deduct-this-week control — which switches OFF the
  /// automatic "deduct by default when this week's gross exceeds R500"
  /// behaviour for this week, so the admin's decision (including a deliberate
  /// choice NOT to deduct) is never re-applied by the auto-deduction pass.
  final bool advanceDeductionOverridden;

  /// A simple one-off addition to this week's net pay — e.g. unpaid wages
  /// owed from a previous week. Unlike advances/savings this isn't tracked
  /// across weeks; it's just entered and added for this specific payslip.
  final double extraEarningsAmount;
  final String extraEarningsNote;

  final bool isWithdrawingSavingsThisWeek;
  final double savingsWithdrawalAmount;
  final String savingsWithdrawalNote;

  /// Internal bookkeeping, mirrors [advanceAppliedToLedger] for savings
  /// withdrawals — informational only.
  final bool savingsWithdrawalApplied;

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
    this.selectedPaymentAccountId,
    this.paymentAccountSnapshot,
    this.paymentStatus = PaymentStatus.notPaid,
    this.paymentNotes = '',
    this.dailyEntries = const {},
    this.isDeductingAdvanceThisWeek = false,
    this.advanceDeductionAmount = 0,
    this.advanceDeductionNote = '',
    this.advanceAppliedToLedger = false,
    this.advanceDeductionOverridden = false,
    this.extraEarningsAmount = 0,
    this.extraEarningsNote = '',
    this.isWithdrawingSavingsThisWeek = false,
    this.savingsWithdrawalAmount = 0,
    this.savingsWithdrawalNote = '',
    this.savingsWithdrawalApplied = false,
    this.grossWage = 0,
    this.netWage = 0,
    this.updatedAt,
    this.updatedBy,
  });

  /// A brand-new payslip for [weekStart], with a blank day for each of the
  /// 7 days, rates snapshotted from the distributor's current profile
  /// (merged over company [settings]), and the profile's default payment
  /// account pre-selected (if it has any saved yet).
  factory PayrollPayslip.blank({
    required String distributorId,
    required String distributorName,
    required DateTime weekStart,
    required PayrollSettings settings,
    required DistributorPayrollProfile profile,
  }) {
    final days = daysInWeek(weekStart);
    final defaultAccount = profile.defaultAccount;
    return PayrollPayslip(
      distributorId: distributorId,
      distributorName: distributorName,
      dayRateSnapshot: profile.resolvedDayRate(settings),
      bonusCodeAmountsSnapshot: profile.resolvedBonusCodeAmounts(settings),
      perSetRateSnapshot: profile.resolvedPerSetRate(settings),
      estimateBonusSnapshot: profile.resolvedEstimateBonus(settings),
      selectedPaymentAccountId: defaultAccount?.id,
      paymentAccountSnapshot: defaultAccount,
      dailyEntries: {
        for (final d in days) dayKeyFor(d): PayrollDailyEntry.empty(d),
      },
    );
  }

  /// Bonus-code amounts to use for this week's wage math. The frozen
  /// [bonusCodeAmountsSnapshot] takes precedence — so editing an existing
  /// code's amount never retroactively rewrites this week's numbers — with
  /// [settings]' current company defaults filling in ONLY codes that weren't
  /// captured when this payslip was first created (i.e. special day codes
  /// added AFTER this week's payslips already existed). Without this, a
  /// newly-added code resolves to 0 for every already-created week.
  Map<String, double> effectiveBonusCodeAmounts(PayrollSettings settings) => {
        ...settings.defaultBonusCodeAmounts,
        ...bonusCodeAmountsSnapshot,
      };

  factory PayrollPayslip.fromMap(
      String distributorId, Map<String, dynamic> data) {
    final entries = <String, PayrollDailyEntry>{};
    final rawEntries = data['dailyEntries'] as Map<String, dynamic>? ?? {};
    for (final e in rawEntries.entries) {
      final parts = e.key.split('-');
      final date = DateTime(
        int.tryParse(parts[0]) ?? DateTime.now().year,
        int.tryParse(parts[1]) ?? 1,
        int.tryParse(parts[2]) ?? 1,
      );
      entries[e.key] = PayrollDailyEntry.fromMap(
          date, Map<String, dynamic>.from(e.value as Map));
    }
    final rawAccountSnapshot =
        data['paymentAccountSnapshot'] as Map<String, dynamic>?;
    return PayrollPayslip(
      distributorId: distributorId,
      distributorName: data['distributorName'] as String? ?? '',
      dayRateSnapshot: (data['dayRateSnapshot'] as num?)?.toDouble() ?? 0,
      bonusCodeAmountsSnapshot:
          (data['bonusCodeAmountsSnapshot'] as Map<String, dynamic>?)
                  ?.map((k, v) => MapEntry(k, (v as num).toDouble())) ??
              const {},
      perSetRateSnapshot: (data['perSetRateSnapshot'] as num?)?.toDouble() ?? 0,
      estimateBonusSnapshot:
          (data['estimateBonusSnapshot'] as num?)?.toDouble() ?? 0,
      selectedPaymentAccountId: data['selectedPaymentAccountId'] as String?,
      paymentAccountSnapshot: rawAccountSnapshot != null
          ? PaymentAccount.fromMap(
              Map<String, dynamic>.from(rawAccountSnapshot))
          : null,
      paymentStatus: PaymentStatus.fromString(data['paymentStatus'] as String?),
      paymentNotes: data['paymentNotes'] as String? ?? '',
      dailyEntries: entries,
      isDeductingAdvanceThisWeek:
          data['isDeductingAdvanceThisWeek'] as bool? ?? false,
      advanceDeductionAmount:
          (data['advanceDeductionAmount'] as num?)?.toDouble() ?? 0,
      advanceDeductionNote: data['advanceDeductionNote'] as String? ?? '',
      advanceAppliedToLedger: data['advanceAppliedToLedger'] as bool? ?? false,
      advanceDeductionOverridden:
          data['advanceDeductionOverridden'] as bool? ?? false,
      extraEarningsAmount:
          (data['extraEarningsAmount'] as num?)?.toDouble() ?? 0,
      extraEarningsNote: data['extraEarningsNote'] as String? ?? '',
      isWithdrawingSavingsThisWeek:
          data['isWithdrawingSavingsThisWeek'] as bool? ?? false,
      savingsWithdrawalAmount:
          (data['savingsWithdrawalAmount'] as num?)?.toDouble() ?? 0,
      savingsWithdrawalNote: data['savingsWithdrawalNote'] as String? ?? '',
      savingsWithdrawalApplied:
          data['savingsWithdrawalApplied'] as bool? ?? false,
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
        'selectedPaymentAccountId': selectedPaymentAccountId,
        'paymentAccountSnapshot': paymentAccountSnapshot?.toMap(),
        'paymentStatus': paymentStatus.name,
        'paymentNotes': paymentNotes,
        'dailyEntries': dailyEntries.map((k, v) => MapEntry(k, v.toMap())),
        'isDeductingAdvanceThisWeek': isDeductingAdvanceThisWeek,
        'advanceDeductionAmount': advanceDeductionAmount,
        'advanceDeductionNote': advanceDeductionNote,
        'advanceAppliedToLedger': advanceAppliedToLedger,
        'advanceDeductionOverridden': advanceDeductionOverridden,
        'extraEarningsAmount': extraEarningsAmount,
        'extraEarningsNote': extraEarningsNote,
        'isWithdrawingSavingsThisWeek': isWithdrawingSavingsThisWeek,
        'savingsWithdrawalAmount': savingsWithdrawalAmount,
        'savingsWithdrawalNote': savingsWithdrawalNote,
        'savingsWithdrawalApplied': savingsWithdrawalApplied,
        'grossWage': grossWage,
        'netWage': netWage,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedBy': updatedBy,
      };

  PayrollPayslip copyWith({
    double? dayRateSnapshot,
    Map<String, double>? bonusCodeAmountsSnapshot,
    double? perSetRateSnapshot,
    double? estimateBonusSnapshot,
    String? selectedPaymentAccountId,
    bool clearSelectedPaymentAccountId = false,
    PaymentAccount? paymentAccountSnapshot,
    bool clearPaymentAccountSnapshot = false,
    PaymentStatus? paymentStatus,
    String? paymentNotes,
    Map<String, PayrollDailyEntry>? dailyEntries,
    bool? isDeductingAdvanceThisWeek,
    double? advanceDeductionAmount,
    String? advanceDeductionNote,
    bool? advanceAppliedToLedger,
    bool? advanceDeductionOverridden,
    double? extraEarningsAmount,
    String? extraEarningsNote,
    bool? isWithdrawingSavingsThisWeek,
    double? savingsWithdrawalAmount,
    String? savingsWithdrawalNote,
    bool? savingsWithdrawalApplied,
    double? grossWage,
    double? netWage,
    String? updatedBy,
  }) {
    return PayrollPayslip(
      distributorId: distributorId,
      distributorName: distributorName,
      dayRateSnapshot: dayRateSnapshot ?? this.dayRateSnapshot,
      bonusCodeAmountsSnapshot:
          bonusCodeAmountsSnapshot ?? this.bonusCodeAmountsSnapshot,
      perSetRateSnapshot: perSetRateSnapshot ?? this.perSetRateSnapshot,
      estimateBonusSnapshot: estimateBonusSnapshot ?? this.estimateBonusSnapshot,
      selectedPaymentAccountId: clearSelectedPaymentAccountId
          ? null
          : (selectedPaymentAccountId ?? this.selectedPaymentAccountId),
      paymentAccountSnapshot: clearPaymentAccountSnapshot
          ? null
          : (paymentAccountSnapshot ?? this.paymentAccountSnapshot),
      paymentStatus: paymentStatus ?? this.paymentStatus,
      paymentNotes: paymentNotes ?? this.paymentNotes,
      dailyEntries: dailyEntries ?? this.dailyEntries,
      isDeductingAdvanceThisWeek:
          isDeductingAdvanceThisWeek ?? this.isDeductingAdvanceThisWeek,
      advanceDeductionAmount:
          advanceDeductionAmount ?? this.advanceDeductionAmount,
      advanceDeductionNote: advanceDeductionNote ?? this.advanceDeductionNote,
      advanceAppliedToLedger:
          advanceAppliedToLedger ?? this.advanceAppliedToLedger,
      advanceDeductionOverridden:
          advanceDeductionOverridden ?? this.advanceDeductionOverridden,
      extraEarningsAmount: extraEarningsAmount ?? this.extraEarningsAmount,
      extraEarningsNote: extraEarningsNote ?? this.extraEarningsNote,
      isWithdrawingSavingsThisWeek:
          isWithdrawingSavingsThisWeek ?? this.isWithdrawingSavingsThisWeek,
      savingsWithdrawalAmount:
          savingsWithdrawalAmount ?? this.savingsWithdrawalAmount,
      savingsWithdrawalNote:
          savingsWithdrawalNote ?? this.savingsWithdrawalNote,
      savingsWithdrawalApplied:
          savingsWithdrawalApplied ?? this.savingsWithdrawalApplied,
      grossWage: grossWage ?? this.grossWage,
      netWage: netWage ?? this.netWage,
      updatedAt: updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }
}
