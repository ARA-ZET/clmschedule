import 'package:flutter/material.dart';

/// Zoho Books invoice status. Distinct from the user-defined
/// `customInvoiceStatuses` used by the Job List — this one is Zoho's fixed
/// vocabulary and is never edited in-app.
enum ZohoInvoiceStatus {
  draft,
  sent,
  overdue,
  paid,
  partiallyPaid,
  unpaid,
  viewed,
  isVoid,
  unknown;

  /// Zoho's wire value (snake_case), used for the `?status=` list filter.
  String get apiValue {
    switch (this) {
      case partiallyPaid:
        return 'partially_paid';
      case isVoid:
        return 'void';
      default:
        return name;
    }
  }

  static ZohoInvoiceStatus parse(String? value) {
    switch (value) {
      case 'draft':
        return draft;
      case 'sent':
        return sent;
      case 'overdue':
        return overdue;
      case 'paid':
        return paid;
      case 'partially_paid':
        return partiallyPaid;
      case 'unpaid':
        return unpaid;
      case 'viewed':
        return viewed;
      case 'void':
        return isVoid;
      default:
        return unknown;
    }
  }

  String get label {
    switch (this) {
      case partiallyPaid:
        return 'Partially paid';
      case isVoid:
        return 'Void';
      default:
        return '${name[0].toUpperCase()}${name.substring(1)}';
    }
  }

  /// Matched to the Zoho Books web UI's status colours.
  Color get color {
    switch (this) {
      case paid:
        return const Color(0xFF2E9E4F);
      case overdue:
        return const Color(0xFFE03E3E);
      case sent:
      case viewed:
        return const Color(0xFF2B7DE9);
      case partiallyPaid:
        return const Color(0xFFE8912D);
      case draft:
      case unpaid:
      case unknown:
        return const Color(0xFF8A97A4);
      case isVoid:
        return const Color(0xFF6B7683);
    }
  }

  /// Void invoices are shown struck through rather than colour-coded.
  bool get isStruckThrough => this == isVoid;
}

/// A single billable line on an invoice.
class ZohoLineItem {
  /// Zoho's id for this line. Present on lines read back from an existing
  /// invoice; empty for lines the user has just added.
  final String lineItemId;

  /// Links the line to an item in Zoho's item catalogue, when it came from
  /// one. Preserved on update so the link is not broken.
  final String itemId;

  final String name;
  final String description;
  final double rate;
  final double quantity;
  final String unit;

  const ZohoLineItem({
    this.lineItemId = '',
    this.itemId = '',
    required this.name,
    this.description = '',
    required this.rate,
    this.quantity = 1.0,
    this.unit = '',
  });

  factory ZohoLineItem.fromJson(Map<String, dynamic> json) {
    return ZohoLineItem(
      lineItemId: json['line_item_id'] as String? ?? '',
      itemId: json['item_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      rate: (json['rate'] as num?)?.toDouble() ?? 0.0,
      quantity: (json['quantity'] as num?)?.toDouble() ?? 1.0,
      unit: json['unit'] as String? ?? '',
    );
  }

  /// Line total as Zoho computes it.
  double get amount => rate * quantity;

  /// [forUpdate] includes `line_item_id`. Without it Zoho drops the existing
  /// line and creates a replacement, losing its identity on the invoice.
  Map<String, dynamic> toJson({bool forUpdate = false}) {
    return {
      if (forUpdate && lineItemId.isNotEmpty) 'line_item_id': lineItemId,
      if (itemId.isNotEmpty) 'item_id': itemId,
      'name': name,
      if (description.isNotEmpty) 'description': description,
      if (unit.isNotEmpty) 'unit': unit,
      'rate': rate,
      'quantity': quantity,
      // No VAT is charged at present, so no `tax_id` is sent and Zoho treats
      // the line as non-taxable. When VAT starts, add the Zoho tax_id here.
    };
  }

  ZohoLineItem copyWith({
    String? name,
    String? description,
    double? rate,
    double? quantity,
    String? unit,
  }) {
    return ZohoLineItem(
      lineItemId: lineItemId,
      itemId: itemId,
      name: name ?? this.name,
      description: description ?? this.description,
      rate: rate ?? this.rate,
      quantity: quantity ?? this.quantity,
      unit: unit ?? this.unit,
    );
  }
}

/// A Zoho Books invoice.
class ZohoInvoice {
  final String invoiceId;
  final String invoiceNumber;
  final String customerId;
  final String customerName;
  final ZohoInvoiceStatus status;
  final DateTime? date;
  final DateTime? dueDate;
  final double total;
  final double subTotal;
  final double balance;
  final String referenceNumber;

  /// Customer-visible notes printed on the invoice.
  final String notes;

  /// Zoho's customer-facing secure link (zohosecurepay.com) — the same URL
  /// Zoho itself emails to customers, where they can view and pay. Safe to
  /// send onward; treat it as public, since anyone holding it can view the
  /// invoice.
  final String invoiceUrl;

  final List<ZohoLineItem> lineItems;

  const ZohoInvoice({
    required this.invoiceId,
    required this.invoiceNumber,
    required this.customerId,
    this.customerName = '',
    this.status = ZohoInvoiceStatus.unknown,
    this.date,
    this.dueDate,
    this.total = 0.0,
    this.subTotal = 0.0,
    this.balance = 0.0,
    this.referenceNumber = '',
    this.notes = '',
    this.invoiceUrl = '',
    this.lineItems = const [],
  });

  factory ZohoInvoice.fromJson(Map<String, dynamic> json) {
    return ZohoInvoice(
      invoiceId: json['invoice_id'] as String? ?? '',
      invoiceNumber: json['invoice_number'] as String? ?? '',
      customerId: json['customer_id'] as String? ?? '',
      customerName: json['customer_name'] as String? ?? '',
      status: ZohoInvoiceStatus.parse(json['status'] as String?),
      date: _parseDate(json['date']),
      dueDate: _parseDate(json['due_date']),
      total: (json['total'] as num?)?.toDouble() ?? 0.0,
      subTotal: (json['sub_total'] as num?)?.toDouble() ?? 0.0,
      balance: (json['balance'] as num?)?.toDouble() ?? 0.0,
      referenceNumber: json['reference_number'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      invoiceUrl: json['invoice_url'] as String? ?? '',
      lineItems: (json['line_items'] as List<dynamic>?)
              ?.map((e) =>
                  ZohoLineItem.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
    );
  }

  /// Zoho returns dates as "yyyy-MM-dd"; empty strings are common.
  static DateTime? _parseDate(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  static String formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  /// Payload for POST /invoices. An empty [invoiceNumber] lets Zoho
  /// auto-number; a non-empty one is preserved by the proxy via
  /// `ignore_auto_number_generation`.
  Map<String, dynamic> toCreateJson() => _toJson(forUpdate: false);

  /// Payload for PUT /invoices/{id}. Line items carry their `line_item_id`
  /// so existing lines are amended rather than replaced.
  Map<String, dynamic> toUpdateJson() => _toJson(forUpdate: true);

  Map<String, dynamic> _toJson({required bool forUpdate}) {
    return {
      'customer_id': customerId,
      if (invoiceNumber.isNotEmpty) 'invoice_number': invoiceNumber,
      if (referenceNumber.isNotEmpty) 'reference_number': referenceNumber,
      if (date != null) 'date': formatDate(date!),
      if (dueDate != null) 'due_date': formatDate(dueDate!),
      if (notes.isNotEmpty) 'notes': notes,
      'line_items':
          lineItems.map((e) => e.toJson(forUpdate: forUpdate)).toList(),
    };
  }
}
