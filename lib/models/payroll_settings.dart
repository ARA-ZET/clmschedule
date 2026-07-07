import 'package:cloud_firestore/cloud_firestore.dart';

/// Company-wide default wage rates, editable in-app (singleton doc at
/// `payrollSettings/config`). Per-distributor `DistributorPayrollProfile`
/// overrides layer on top of these.
class PayrollSettings {
  final double defaultDayRate;

  /// Special day-type code -> flat bonus amount, e.g. `DR` (driving) -> 155.
  final Map<String, double> defaultBonusCodeAmounts;

  /// Special day-type code -> human label, e.g. `DR` -> "Driving".
  final Map<String, String> bonusCodeLabels;

  /// Ordered list of known codes, admin-extensible (drives dropdown order).
  final List<String> bonusCodes;

  /// Bonus-per-flyer-set beyond the first, for a normal distribution day.
  final double defaultPerSetRate;

  /// Bonus for hitting the estimate with no issue logged, normal day only.
  final double defaultEstimateBonus;

  /// Default transport fare per trip (ZAR), for distributors who are
  /// transport-eligible and don't have their own fare override.
  final double defaultTransportFare;

  final DateTime? updatedAt;

  const PayrollSettings({
    required this.defaultDayRate,
    required this.defaultBonusCodeAmounts,
    required this.bonusCodeLabels,
    required this.bonusCodes,
    required this.defaultPerSetRate,
    required this.defaultEstimateBonus,
    required this.defaultTransportFare,
    this.updatedAt,
  });

  /// Seed values recreated from the original wage-slip Google Sheet.
  factory PayrollSettings.defaults() => const PayrollSettings(
        defaultDayRate: 213,
        defaultBonusCodeAmounts: {
          'DR': 155,
          'SC': 73,
          'TL': 73,
          'WC': 90,
          'HC': -83,
          'HW': -60,
          'WM': 67,
        },
        bonusCodeLabels: {
          'DR': 'Driving',
          'SC': 'Scooter',
          'TL': 'Traffic light handout',
          'WC': 'Window cleaning (full day)',
          'HC': 'Half-day collection',
          'HW': 'Half-day window cleaning',
          'WM': 'Window cleaning + distribution',
        },
        bonusCodes: ['DR', 'SC', 'TL', 'WC', 'HC', 'HW', 'WM'],
        defaultPerSetRate: 37,
        defaultEstimateBonus: 45,
        defaultTransportFare: 10.5,
      );

  factory PayrollSettings.fromMap(Map<String, dynamic> data) {
    final defaults = PayrollSettings.defaults();
    return PayrollSettings(
      defaultDayRate:
          (data['defaultDayRate'] as num?)?.toDouble() ?? defaults.defaultDayRate,
      defaultBonusCodeAmounts: (data['defaultBonusCodeAmounts']
                  as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, (v as num).toDouble())) ??
          defaults.defaultBonusCodeAmounts,
      bonusCodeLabels: (data['bonusCodeLabels'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          defaults.bonusCodeLabels,
      bonusCodes: (data['bonusCodes'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          defaults.bonusCodes,
      defaultPerSetRate: (data['defaultPerSetRate'] as num?)?.toDouble() ??
          defaults.defaultPerSetRate,
      defaultEstimateBonus: (data['defaultEstimateBonus'] as num?)
              ?.toDouble() ??
          defaults.defaultEstimateBonus,
      defaultTransportFare: (data['defaultTransportFare'] as num?)
              ?.toDouble() ??
          defaults.defaultTransportFare,
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
        'defaultDayRate': defaultDayRate,
        'defaultBonusCodeAmounts': defaultBonusCodeAmounts,
        'bonusCodeLabels': bonusCodeLabels,
        'bonusCodes': bonusCodes,
        'defaultPerSetRate': defaultPerSetRate,
        'defaultEstimateBonus': defaultEstimateBonus,
        'defaultTransportFare': defaultTransportFare,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      };

  PayrollSettings copyWith({
    double? defaultDayRate,
    Map<String, double>? defaultBonusCodeAmounts,
    Map<String, String>? bonusCodeLabels,
    List<String>? bonusCodes,
    double? defaultPerSetRate,
    double? defaultEstimateBonus,
    double? defaultTransportFare,
  }) {
    return PayrollSettings(
      defaultDayRate: defaultDayRate ?? this.defaultDayRate,
      defaultBonusCodeAmounts:
          defaultBonusCodeAmounts ?? this.defaultBonusCodeAmounts,
      bonusCodeLabels: bonusCodeLabels ?? this.bonusCodeLabels,
      bonusCodes: bonusCodes ?? this.bonusCodes,
      defaultPerSetRate: defaultPerSetRate ?? this.defaultPerSetRate,
      defaultEstimateBonus: defaultEstimateBonus ?? this.defaultEstimateBonus,
      defaultTransportFare:
          defaultTransportFare ?? this.defaultTransportFare,
      updatedAt: updatedAt,
    );
  }
}
