/// One entry in Zoho Books' item catalogue.
///
/// The Zoho counterpart to [XeroItem], and the reason
/// `CustomJobType.accountingItemCode` was named provider-neutrally: a job type
/// stores whichever identifier its company's books use.
///
/// **That identifier is not the same shape as Xero's.** Xero items are
/// addressed by a human-chosen `Code` ("DIST-1000"); Zoho has no such field and
/// addresses items by an opaque numeric `item_id`. So a stored value is only
/// meaningful against the provider it came from — which is fine, because a job
/// type belongs to exactly one company.
class ZohoItem {
  final String itemId;
  final String name;

  /// Sales description — what lands on the invoice line.
  final String description;

  /// Unit price.
  final double rate;

  /// "qty", "hrs", "1000" — free text in Zoho.
  final String unit;

  /// Zoho's own stock-keeping code, where one is set. Display only: the link
  /// is always by [itemId].
  final String sku;

  final String status;

  const ZohoItem({
    required this.itemId,
    this.name = '',
    this.description = '',
    this.rate = 0.0,
    this.unit = '',
    this.sku = '',
    this.status = 'active',
  });

  factory ZohoItem.fromJson(Map<String, dynamic> json) {
    return ZohoItem(
      itemId: json['item_id']?.toString() ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      rate: (json['rate'] as num?)?.toDouble() ?? 0.0,
      unit: json['unit'] as String? ?? '',
      sku: json['sku'] as String? ?? '',
      status: json['status'] as String? ?? 'active',
    );
  }

  bool get isActive => status.toLowerCase() == 'active';

  /// Falls back to the id so a picker never renders a blank row.
  String get displayName => name.isNotEmpty ? name : itemId;

  String get displayLabel =>
      sku.isEmpty ? displayName : '$sku — $displayName';

  /// What the invoice line should say.
  ///
  /// Zoho's line has both a `name` and a `description`, so unlike Xero this
  /// does not have to collapse them — the name identifies the service and the
  /// description elaborates. This returns the elaboration, falling back to the
  /// name when there is none.
  String get lineDescription =>
      description.isNotEmpty ? description : displayName;
}
