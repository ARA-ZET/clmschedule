import 'payment_account.dart';
import 'payroll_settings.dart';

/// Per-distributor payroll config: rate overrides + saved payment accounts.
/// Nested (additive) on `Distributor.payroll`. Any rate override left `null`
/// falls back to the company-wide `PayrollSettings` default.
class DistributorPayrollProfile {
  final double? dayRate;

  /// Special day-type code -> flat bonus override; codes absent from this
  /// map fall back to `PayrollSettings.defaultBonusCodeAmounts`.
  final Map<String, double> bonusCodeAmounts;
  final double? perSetRate;
  final double? estimateBonus;

  /// Every eWallet number / bank account this distributor can be paid
  /// through. A distributor commonly alternates between more than one, so
  /// this is a list rather than a single slot — each payroll week just
  /// records which entry it used that week (see `PayrollPayslip`).
  final List<PaymentAccount> paymentAccounts;

  /// Which account a brand-new week's payslip is seeded with.
  final String? defaultPaymentAccountId;

  const DistributorPayrollProfile({
    this.dayRate,
    this.bonusCodeAmounts = const {},
    this.perSetRate,
    this.estimateBonus,
    this.paymentAccounts = const [],
    this.defaultPaymentAccountId,
  });

  factory DistributorPayrollProfile.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const DistributorPayrollProfile();

    final rawAccounts = data['paymentAccounts'] as List<dynamic>?;
    var accounts = rawAccounts
            ?.map((e) =>
                PaymentAccount.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList() ??
        <PaymentAccount>[];
    var defaultId = data['defaultPaymentAccountId'] as String?;

    // One-time migration from the old single-account fields (bankName,
    // ewalletNumber, etc.) that predate the multi-account model. Once this
    // profile is saved again it'll be written in the new shape.
    if (accounts.isEmpty) {
      final legacyMethod = data['paymentMethod'] as String?;
      final legacyBankName = data['bankName'] as String?;
      final legacyAccountHolder = data['bankAccountHolder'] as String?;
      final legacyAccountNumber = data['bankAccountNumber'] as String?;
      final legacyBranchCode = data['bankBranchCode'] as String?;
      final legacyEwalletNumber = data['ewalletNumber'] as String?;
      final hasLegacyData = legacyMethod != null ||
          legacyBankName != null ||
          legacyAccountNumber != null ||
          legacyEwalletNumber != null;
      if (hasLegacyData) {
        final migrated = PaymentAccount(
          id: 'migrated',
          method: legacyMethod ?? 'eWallet',
          bankName: legacyBankName,
          accountHolder: legacyAccountHolder,
          accountNumber: legacyAccountNumber,
          branchCode: legacyBranchCode,
          ewalletNumber: legacyEwalletNumber,
        );
        accounts = [migrated];
        defaultId = migrated.id;
      }
    }

    return DistributorPayrollProfile(
      dayRate: (data['dayRate'] as num?)?.toDouble(),
      bonusCodeAmounts: (data['bonusCodeAmounts'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, (v as num).toDouble())) ??
          const {},
      perSetRate: (data['perSetRate'] as num?)?.toDouble(),
      estimateBonus: (data['estimateBonus'] as num?)?.toDouble(),
      paymentAccounts: accounts,
      defaultPaymentAccountId: defaultId,
    );
  }

  Map<String, dynamic> toMap() => {
        'dayRate': dayRate,
        'bonusCodeAmounts': bonusCodeAmounts,
        'perSetRate': perSetRate,
        'estimateBonus': estimateBonus,
        'paymentAccounts': paymentAccounts.map((a) => a.toMap()).toList(),
        'defaultPaymentAccountId': defaultPaymentAccountId,
      };

  /// The account a brand-new week should be seeded with: the one flagged
  /// default, or the first saved account, or `null` if there are none yet.
  PaymentAccount? get defaultAccount {
    if (paymentAccounts.isEmpty) return null;
    for (final a in paymentAccounts) {
      if (a.id == defaultPaymentAccountId) return a;
    }
    return paymentAccounts.first;
  }

  PaymentAccount? accountById(String? id) {
    if (id == null) return null;
    for (final a in paymentAccounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Effective day rate: this profile's override, else the company default.
  double resolvedDayRate(PayrollSettings settings) =>
      dayRate ?? settings.defaultDayRate;

  /// Effective bonus-code amounts: company defaults with this profile's
  /// per-code overrides layered on top.
  Map<String, double> resolvedBonusCodeAmounts(PayrollSettings settings) => {
        ...settings.defaultBonusCodeAmounts,
        ...bonusCodeAmounts,
      };

  double resolvedPerSetRate(PayrollSettings settings) =>
      perSetRate ?? settings.defaultPerSetRate;

  double resolvedEstimateBonus(PayrollSettings settings) =>
      estimateBonus ?? settings.defaultEstimateBonus;

  DistributorPayrollProfile copyWith({
    double? dayRate,
    bool clearDayRate = false,
    Map<String, double>? bonusCodeAmounts,
    double? perSetRate,
    bool clearPerSetRate = false,
    double? estimateBonus,
    bool clearEstimateBonus = false,
    List<PaymentAccount>? paymentAccounts,
    String? defaultPaymentAccountId,
    bool clearDefaultPaymentAccountId = false,
  }) {
    return DistributorPayrollProfile(
      dayRate: clearDayRate ? null : (dayRate ?? this.dayRate),
      bonusCodeAmounts: bonusCodeAmounts ?? this.bonusCodeAmounts,
      perSetRate: clearPerSetRate ? null : (perSetRate ?? this.perSetRate),
      estimateBonus:
          clearEstimateBonus ? null : (estimateBonus ?? this.estimateBonus),
      paymentAccounts: paymentAccounts ?? this.paymentAccounts,
      defaultPaymentAccountId: clearDefaultPaymentAccountId
          ? null
          : (defaultPaymentAccountId ?? this.defaultPaymentAccountId),
    );
  }
}
