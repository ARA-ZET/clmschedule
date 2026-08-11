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

  Color get color {
    switch (this) {
      case paid:
        return Colors.green;
      case overdue:
        return Colors.red;
      case sent:
      case viewed:
        return Colors.blue;
      case partiallyPaid:
        return Colors.orange;
      case draft:
      case unpaid:
      case unknown:
        return Colors.grey;
      case isVoid:
        return Colors.grey.shade600;
    }
  }

  /// Void invoices are shown struck through rather than colour-coded.
  bool get isStruckThrough => this == isVoid;
}

/// A single billable line on an invoice.
class ZohoLineItem {
  final String name;
  final String description;
  final double rate;
  final double quantity;

  const ZohoLineItem({
    required this.name,
    this.description = '',
    required this.rate,
    this.quantity = 1.0,
  });

  factory ZohoLineItem.fromJson(Map<String, dynamic> json) {
    return ZohoLineItem(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      rate: (json['rate'] as num?)?.toDouble() ?? 0.0,
      quantity: (json['quantity'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      if (description.isNotEmpty) 'description': description,
      'rate': rate,
      'quantity': quantity,
      // No VAT is charged at present, so no `tax_id` is sent and Zoho treats
      // the line as non-taxable. When VAT starts, add the Zoho tax_id here.
    };
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
  final double balance;
  final String referenceNumber;
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
    this.balance = 0.0,
    this.referenceNumber = '',
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
      balance: (json['balance'] as num?)?.toDouble() ?? 0.0,
      referenceNumber: json['reference_number'] as String? ?? '',
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
  Map<String, dynamic> toCreateJson() {
    return {
      'customer_id': customerId,
      if (invoiceNumber.isNotEmpty) 'invoice_number': invoiceNumber,
      if (referenceNumber.isNotEmpty) 'reference_number': referenceNumber,
      if (date != null) 'date': formatDate(date!),
      if (dueDate != null) 'due_date': formatDate(dueDate!),
      'line_items': lineItems.map((e) => e.toJson()).toList(),
    };
  }
}
