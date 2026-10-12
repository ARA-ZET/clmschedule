/// Organisation-level Xero settings, read to populate the setup dropdowns in
/// the company management dialog.
///
/// None of this is hardcoded: the sales account code and the VAT tax type are
/// organisation-specific, and Xero's South African vocabulary differs from the
/// demo company's. They are chosen once by an admin and stored in
/// `Company.providerConfig`.
library;

/// A revenue account from the chart of accounts.
class XeroAccount {
  final String accountId;

  /// What goes into `providerConfig.salesAccountCode` — e.g. "200".
  final String code;

  final String name;

  /// `REVENUE`, `SALES`, etc.
  final String type;

  /// The tax type applied when a line omits its own `TaxType`.
  final String taxType;

  final String status;

  const XeroAccount({
    this.accountId = '',
    required this.code,
    required this.name,
    this.type = '',
    this.taxType = '',
    this.status = 'ACTIVE',
  });

  factory XeroAccount.fromJson(Map<String, dynamic> json) {
    return XeroAccount(
      accountId: json['AccountID'] as String? ?? '',
      code: json['Code'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      type: json['Type'] as String? ?? '',
      taxType: json['TaxType'] as String? ?? '',
      status: json['Status'] as String? ?? 'ACTIVE',
    );
  }

  bool get isActive => status.toUpperCase() == 'ACTIVE';

  String get displayLabel => '$code — $name';
}

/// One entry in Xero's Products & Services catalogue.
///
/// This is what lets a job type carry its own pricing: CLM's standard rates —
/// per-1000 distribution and the like — live in Xero rather than being retyped
/// per invoice, so the books stay the source of truth for what a service costs.
///
/// **The sales figures are nested.** Xero puts price, account and tax rate under
/// `SalesDetails`, not on the item itself, and a purchase-only item has no
/// `SalesDetails` at all — which is why the proxy filters on `IsSold==true`
/// rather than letting priceless rows reach a line picker.
class XeroItem {
  final String itemId;

  /// The catalogue code, e.g. "DIST-1000". This is what goes onto an invoice
  /// line as `ItemCode`, and what a job type stores to bind itself to an item.
  final String code;

  final String name;

  /// Sales description — what appears on the invoice line.
  final String description;

  /// Unit price from `SalesDetails`, or 0 when the item carries none.
  final double unitPrice;

  /// Revenue account this item posts to. Overrides the company default.
  final String accountCode;

  /// Tax type for the line. Overrides the company default.
  final String taxType;

  final bool isSold;

  const XeroItem({
    this.itemId = '',
    required this.code,
    this.name = '',
    this.description = '',
    this.unitPrice = 0.0,
    this.accountCode = '',
    this.taxType = '',
    this.isSold = true,
  });

  factory XeroItem.fromJson(Map<String, dynamic> json) {
    final sales = json['SalesDetails'] as Map<dynamic, dynamic>?;

    return XeroItem(
      itemId: json['ItemID'] as String? ?? '',
      code: json['Code'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      // Xero's `Description` IS the sales description; `PurchaseDescription`
      // is the separate buying-side one, which must not leak onto an invoice.
      description: json['Description'] as String? ?? '',
      unitPrice: (sales?['UnitPrice'] as num?)?.toDouble() ?? 0.0,
      accountCode: sales?['AccountCode'] as String? ?? '',
      taxType: sales?['TaxType'] as String? ?? '',
      isSold: json['IsSold'] as bool? ?? true,
    );
  }

  /// Falls back to the code when an item has no name, so a picker never shows
  /// a blank row.
  String get displayName => name.isNotEmpty ? name : code;

  String get displayLabel =>
      code.isEmpty ? displayName : '$code — $displayName';

  /// What the invoice line should say. Prefers the sales description, which is
  /// usually the fuller sentence, and falls back to the name.
  String get lineDescription =>
      description.isNotEmpty ? description : displayName;
}

/// A tax rate. The one CLM wants is the 15% output VAT.
class XeroTaxRate {
  /// What goes into `providerConfig.salesTaxType` — e.g. "OUTPUT2".
  final String taxType;

  final String name;

  /// The rate actually applied, as a percentage. 15.0 for South African VAT.
  final double effectiveRate;

  final String status;

  /// Whether this rate may be used on revenue accounts. A purchases-only rate
  /// on a sales invoice is rejected by Xero.
  final bool canApplyToRevenue;

  const XeroTaxRate({
    required this.taxType,
    required this.name,
    this.effectiveRate = 0.0,
    this.status = 'ACTIVE',
    this.canApplyToRevenue = false,
  });

  factory XeroTaxRate.fromJson(Map<String, dynamic> json) {
    return XeroTaxRate(
      taxType: json['TaxType'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      effectiveRate: (json['EffectiveRate'] as num?)?.toDouble() ?? 0.0,
      status: json['Status'] as String? ?? 'ACTIVE',
      canApplyToRevenue: json['CanApplyToRevenue'] as bool? ?? false,
    );
  }

  bool get isActive => status.toUpperCase() == 'ACTIVE';

  String get displayLabel =>
      '$name — ${effectiveRate.toStringAsFixed(effectiveRate.truncateToDouble() == effectiveRate ? 0 : 2)}%';
}

/// Enough of the organisation to confirm which books are connected.
class XeroOrganisation {
  final String name;
  final String legalName;
  final String countryCode;
  final String baseCurrency;
  final bool isDemoCompany;
  final String shortCode;

  const XeroOrganisation({
    required this.name,
    this.legalName = '',
    this.countryCode = '',
    this.baseCurrency = '',
    this.isDemoCompany = false,
    this.shortCode = '',
  });

  factory XeroOrganisation.fromJson(Map<String, dynamic> json) {
    return XeroOrganisation(
      name: json['Name'] as String? ?? '',
      legalName: json['LegalName'] as String? ?? '',
      countryCode: json['CountryCode'] as String? ?? '',
      baseCurrency: json['BaseCurrency'] as String? ?? '',
      isDemoCompany: json['IsDemoCompany'] as bool? ?? false,
      shortCode: json['ShortCode'] as String? ?? '',
    );
  }
}

/// Whether the backend currently holds a usable Xero connection. Never carries
/// a token — the proxy deliberately does not expose one.
class XeroConnectionStatus {
  final bool connected;
  final String tenantId;
  final String tenantName;
  final DateTime? lastRefreshAt;

  const XeroConnectionStatus({
    required this.connected,
    this.tenantId = '',
    this.tenantName = '',
    this.lastRefreshAt,
  });

  factory XeroConnectionStatus.fromJson(Map<String, dynamic> json) {
    final last = json['lastRefreshAt'];
    return XeroConnectionStatus(
      connected: json['connected'] as bool? ?? false,
      tenantId: json['tenantId'] as String? ?? '',
      tenantName: json['tenantName'] as String? ?? '',
      lastRefreshAt: last is num
          ? DateTime.fromMillisecondsSinceEpoch(last.toInt())
          : null,
    );
  }
}
