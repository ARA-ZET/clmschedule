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

  // ── Company details ──────────────────────────────────────────────────
  // Shown on payslips and other printed documents. Editable in-app instead
  // of hardcoded, so a logo change or address move doesn't need a code
  // change.
  final String companyName;
  final String companyRegistrationNo;
  final String companyVatNo;
  final String companyAddress;
  final String companyPhone;
  final String companyEmail;

  /// Firebase Storage download URL for the uploaded logo, if any. Falls
  /// back to the bundled `assets/logo.png` when null/empty.
  final String? companyLogoUrl;

  final DateTime? updatedAt;

  const PayrollSettings({
    required this.defaultDayRate,
    required this.defaultBonusCodeAmounts,
    required this.bonusCodeLabels,
    required this.bonusCodes,
    required this.defaultPerSetRate,
    required this.defaultEstimateBonus,
    this.companyName = '',
    this.companyRegistrationNo = '',
    this.companyVatNo = '',
    this.companyAddress = '',
    this.companyPhone = '',
    this.companyEmail = '',
    this.companyLogoUrl,
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
        companyName: 'Community Life Media',
        companyRegistrationNo: '2013/128702/07',
        companyVatNo: '4500285780',
        companyAddress:
            'Unit 69, 27, 7th Avenue\nThe Old Timber Yard, Maitland\nCape Town, 7405',
        companyPhone: '+27 71 909 0839',
      );

  factory PayrollSettings.fromMap(Map<String, dynamic> data) {
    final defaults = PayrollSettings.defaults();
    return PayrollSettings(
      defaultDayRate: (data['defaultDayRate'] as num?)?.toDouble() ??
          defaults.defaultDayRate,
      defaultBonusCodeAmounts:
          (data['defaultBonusCodeAmounts'] as Map<String, dynamic>?)
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
      defaultEstimateBonus:
          (data['defaultEstimateBonus'] as num?)?.toDouble() ??
              defaults.defaultEstimateBonus,
      companyName: data['companyName'] as String? ?? defaults.companyName,
      companyRegistrationNo: data['companyRegistrationNo'] as String? ??
          defaults.companyRegistrationNo,
      companyVatNo: data['companyVatNo'] as String? ?? defaults.companyVatNo,
      companyAddress:
          data['companyAddress'] as String? ?? defaults.companyAddress,
      companyPhone: data['companyPhone'] as String? ?? defaults.companyPhone,
      companyEmail: data['companyEmail'] as String? ?? defaults.companyEmail,
      companyLogoUrl: data['companyLogoUrl'] as String?,
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
        'companyName': companyName,
        'companyRegistrationNo': companyRegistrationNo,
        'companyVatNo': companyVatNo,
        'companyAddress': companyAddress,
        'companyPhone': companyPhone,
        'companyEmail': companyEmail,
        'companyLogoUrl': companyLogoUrl,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      };

  PayrollSettings copyWith({
    double? defaultDayRate,
    Map<String, double>? defaultBonusCodeAmounts,
    Map<String, String>? bonusCodeLabels,
    List<String>? bonusCodes,
    double? defaultPerSetRate,
    double? defaultEstimateBonus,
    String? companyName,
    String? companyRegistrationNo,
    String? companyVatNo,
    String? companyAddress,
    String? companyPhone,
    String? companyEmail,
    String? companyLogoUrl,
    bool clearCompanyLogoUrl = false,
  }) {
    return PayrollSettings(
      defaultDayRate: defaultDayRate ?? this.defaultDayRate,
      defaultBonusCodeAmounts:
          defaultBonusCodeAmounts ?? this.defaultBonusCodeAmounts,
      bonusCodeLabels: bonusCodeLabels ?? this.bonusCodeLabels,
      bonusCodes: bonusCodes ?? this.bonusCodes,
      defaultPerSetRate: defaultPerSetRate ?? this.defaultPerSetRate,
      defaultEstimateBonus: defaultEstimateBonus ?? this.defaultEstimateBonus,
      companyName: companyName ?? this.companyName,
      companyRegistrationNo:
          companyRegistrationNo ?? this.companyRegistrationNo,
      companyVatNo: companyVatNo ?? this.companyVatNo,
      companyAddress: companyAddress ?? this.companyAddress,
      companyPhone: companyPhone ?? this.companyPhone,
      companyEmail: companyEmail ?? this.companyEmail,
      companyLogoUrl:
          clearCompanyLogoUrl ? null : (companyLogoUrl ?? this.companyLogoUrl),
      updatedAt: updatedAt,
    );
  }
}
