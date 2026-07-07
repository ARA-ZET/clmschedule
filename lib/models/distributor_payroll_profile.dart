import 'payroll_settings.dart';

/// Per-distributor payroll config: rate overrides + bank details.
/// Nested (additive) on `Distributor.payroll`. Any override left `null`
/// falls back to the company-wide `PayrollSettings` default.
class DistributorPayrollProfile {
  final double? dayRate;

  /// Special day-type code -> flat bonus override; codes absent from this
  /// map fall back to `PayrollSettings.defaultBonusCodeAmounts`.
  final Map<String, double> bonusCodeAmounts;
  final double? perSetRate;
  final double? estimateBonus;

  /// Not every distributor has a transport-fare line item on their payslip.
  final bool transportEligible;
  final double? transportFarePerTrip;

  final String? bankName;
  final String? bankAccountHolder;
  final String? bankAccountNumber;
  final String? bankBranchCode;
  final String? bankAccountType;
  final String paymentMethod;

  const DistributorPayrollProfile({
    this.dayRate,
    this.bonusCodeAmounts = const {},
    this.perSetRate,
    this.estimateBonus,
    this.transportEligible = false,
    this.transportFarePerTrip,
    this.bankName,
    this.bankAccountHolder,
    this.bankAccountNumber,
    this.bankBranchCode,
    this.bankAccountType,
    this.paymentMethod = 'EFT',
  });

  factory DistributorPayrollProfile.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const DistributorPayrollProfile();
    return DistributorPayrollProfile(
      dayRate: (data['dayRate'] as num?)?.toDouble(),
      bonusCodeAmounts: (data['bonusCodeAmounts'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, (v as num).toDouble())) ??
          const {},
      perSetRate: (data['perSetRate'] as num?)?.toDouble(),
      estimateBonus: (data['estimateBonus'] as num?)?.toDouble(),
      transportEligible: data['transportEligible'] as bool? ?? false,
      transportFarePerTrip: (data['transportFarePerTrip'] as num?)
          ?.toDouble(),
      bankName: data['bankName'] as String?,
      bankAccountHolder: data['bankAccountHolder'] as String?,
      bankAccountNumber: data['bankAccountNumber'] as String?,
      bankBranchCode: data['bankBranchCode'] as String?,
      bankAccountType: data['bankAccountType'] as String?,
      paymentMethod: data['paymentMethod'] as String? ?? 'EFT',
    );
  }

  Map<String, dynamic> toMap() => {
        'dayRate': dayRate,
        'bonusCodeAmounts': bonusCodeAmounts,
        'perSetRate': perSetRate,
        'estimateBonus': estimateBonus,
        'transportEligible': transportEligible,
        'transportFarePerTrip': transportFarePerTrip,
        'bankName': bankName,
        'bankAccountHolder': bankAccountHolder,
        'bankAccountNumber': bankAccountNumber,
        'bankBranchCode': bankBranchCode,
        'bankAccountType': bankAccountType,
        'paymentMethod': paymentMethod,
      };

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

  double resolvedTransportFarePerTrip(PayrollSettings settings) =>
      transportFarePerTrip ?? settings.defaultTransportFare;

  DistributorPayrollProfile copyWith({
    double? dayRate,
    bool clearDayRate = false,
    Map<String, double>? bonusCodeAmounts,
    double? perSetRate,
    bool clearPerSetRate = false,
    double? estimateBonus,
    bool clearEstimateBonus = false,
    bool? transportEligible,
    double? transportFarePerTrip,
    bool clearTransportFarePerTrip = false,
    String? bankName,
    String? bankAccountHolder,
    String? bankAccountNumber,
    String? bankBranchCode,
    String? bankAccountType,
    String? paymentMethod,
  }) {
    return DistributorPayrollProfile(
      dayRate: clearDayRate ? null : (dayRate ?? this.dayRate),
      bonusCodeAmounts: bonusCodeAmounts ?? this.bonusCodeAmounts,
      perSetRate: clearPerSetRate ? null : (perSetRate ?? this.perSetRate),
      estimateBonus:
          clearEstimateBonus ? null : (estimateBonus ?? this.estimateBonus),
      transportEligible: transportEligible ?? this.transportEligible,
      transportFarePerTrip: clearTransportFarePerTrip
          ? null
          : (transportFarePerTrip ?? this.transportFarePerTrip),
      bankName: bankName ?? this.bankName,
      bankAccountHolder: bankAccountHolder ?? this.bankAccountHolder,
      bankAccountNumber: bankAccountNumber ?? this.bankAccountNumber,
      bankBranchCode: bankBranchCode ?? this.bankBranchCode,
      bankAccountType: bankAccountType ?? this.bankAccountType,
      paymentMethod: paymentMethod ?? this.paymentMethod,
    );
  }
}
