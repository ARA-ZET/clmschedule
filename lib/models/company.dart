import 'package:flutter/material.dart';

/// The accounting system a company invoices through.
///
/// Held on the **company**, not the job type: every CLM job type bills through
/// the same Xero organisation, and duplicating that choice per job type would
/// let them drift apart the first time someone added one.
enum AccountingProvider {
  none('Not invoiced in app'),
  zoho('Zoho Books'),
  xero('Xero'),
  sage('Sage Accounting');

  const AccountingProvider(this.label);
  final String label;

  static AccountingProvider parse(String? value) {
    return AccountingProvider.values.firstWhere(
      (p) => p.name == value,
      orElse: () => none,
    );
  }

  /// Whether the app can raise invoices for this provider yet. Zoho and Xero
  /// are built; Sage is researched but not implemented, so the UI can say so
  /// rather than offering a dead action.
  bool get isImplemented => this == zoho || this == xero || this == none;

  /// Which books a job type's invoices should be raised in.
  ///
  /// [fromCompany] is what `CompanyProvider.providerForJobType` returned, and
  /// normally settles it. The rest is a safety net for a company document with
  /// no provider recorded: before the company link existed, "is this invoiced?"
  /// *was* `appearsOnCollectionSchedule`, so a misconfigured company falls back
  /// to that rather than silently making Junk & Stuff's jobs uninvoiceable.
  ///
  /// [createsInvoices] is checked first and is absolute — a job type marked as
  /// not raising invoices (internal work such as returning flyers) never gets
  /// an invoicing section, whatever its company says.
  static AccountingProvider forJobType({
    required AccountingProvider fromCompany,
    required bool createsInvoices,
    required bool appearsOnCollectionSchedule,
  }) {
    if (!createsInvoices) return none;
    if (fromCompany != none) return fromCompany;
    return appearsOnCollectionSchedule ? zoho : none;
  }
}

/// One of the businesses whose work is managed in this app — Community Life
/// Media, Happy Sun, Junk & Stuff, and any added later.
///
/// Job types point at a company via `CustomJobType.companyId`. That link is the
/// single source of truth for "whose job is this", replacing the old inference
/// from behaviour flags (`appearsOnCollectionSchedule` meant Junk & Stuff,
/// `isHappySunService` meant Happy Sun, neither meant CLM — and CLM was
/// therefore not stored anywhere at all).
///
/// Those flags still exist and still drive UI placement and features. They
/// describe **behaviour**; this describes **ownership**. Keeping them separate
/// is the point: a Junk & Stuff job type that does not belong on the Collection
/// Schedule is now expressible.
class Company {
  final String id;
  final String name;

  /// Short form for chips and column labels, e.g. "CLM".
  final String shortName;

  final AccountingProvider accountingProvider;

  /// Provider-specific settings — Zoho's `organizationId`, Xero's account
  /// code and tax type.
  /// Free-form so a new provider does not need a schema change.
  final Map<String, String> providerConfig;

  final int order;
  final bool active;
  final int? colorValue;

  const Company({
    required this.id,
    required this.name,
    this.shortName = '',
    this.accountingProvider = AccountingProvider.none,
    this.providerConfig = const {},
    this.order = 0,
    this.active = true,
    this.colorValue,
  });

  factory Company.fromMap(Map<String, dynamic> map) {
    return Company(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      shortName: map['shortName'] as String? ?? '',
      accountingProvider:
          AccountingProvider.parse(map['accountingProvider'] as String?),
      providerConfig: Map<String, String>.from(
        (map['providerConfig'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), (v ?? '').toString()),
            ) ??
            const {},
      ),
      order: (map['order'] as num?)?.toInt() ?? 0,
      active: map['active'] as bool? ?? true,
      colorValue: (map['colorValue'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'shortName': shortName,
      'accountingProvider': accountingProvider.name,
      'providerConfig': providerConfig,
      'order': order,
      'active': active,
      if (colorValue != null) 'colorValue': colorValue,
    };
  }

  /// Label for chips — short name when set, otherwise the full name.
  String get displayLabel => shortName.isNotEmpty ? shortName : name;

  Color get color =>
      colorValue != null ? Color(colorValue!) : const Color(0xFF7A8794);

  Company copyWith({
    String? id,
    String? name,
    String? shortName,
    AccountingProvider? accountingProvider,
    Map<String, String>? providerConfig,
    int? order,
    bool? active,
    int? colorValue,
  }) {
    return Company(
      id: id ?? this.id,
      name: name ?? this.name,
      shortName: shortName ?? this.shortName,
      accountingProvider: accountingProvider ?? this.accountingProvider,
      providerConfig: providerConfig ?? this.providerConfig,
      order: order ?? this.order,
      active: active ?? this.active,
      colorValue: colorValue ?? this.colorValue,
    );
  }

  /// Well-known ids used by the one-off derivation from the legacy flags.
  /// Stable strings rather than generated ids so the migration is repeatable
  /// and the seed can be reasoned about.
  static const String clmId = 'clm';
  static const String happySunId = 'happySun';
  static const String junkAndStuffId = 'junkAndStuff';

  /// The three companies as they exist today, used to seed the collection.
  static List<Company> get seed => const [
        Company(
          id: clmId,
          name: 'Community Life Media',
          shortName: 'CLM',
          accountingProvider: AccountingProvider.xero,
          order: 0,
          colorValue: 0xFF2B7DE9,
        ),
        Company(
          id: happySunId,
          name: 'Happy Sun',
          shortName: 'Happy Sun',
          // Its own organisation under the same Zoho login as Junk & Stuff —
          // see ZohoOrg.
          accountingProvider: AccountingProvider.zoho,
          order: 1,
          colorValue: 0xFFE8912D,
        ),
        Company(
          id: junkAndStuffId,
          name: 'Junk & Stuff',
          shortName: 'Junk & Stuff',
          accountingProvider: AccountingProvider.zoho,
          order: 2,
          colorValue: 0xFF2E9E4F,
        ),
      ];
}
