import 'package:intl/intl.dart';

import 'invoice_message_subject.dart';

/// Which kind of invoice a message template is written for.
///
/// Deliberately coarser than either provider's status list — the wording you
/// use is driven by whether money is owed, not by every state the ledger
/// tracks. Being coarse is also what lets one set of templates serve both
/// Zoho and Xero, whose status vocabularies do not line up.
enum InvoiceMessageCategory {
  any('Any invoice'),
  unpaid('Unpaid'),
  overdue('Overdue'),
  paid('Paid');

  const InvoiceMessageCategory(this.label);
  final String label;

  /// The category a given invoice falls into. `any` is never returned — it is
  /// a template-side wildcard, not a state an invoice can be in.
  static InvoiceMessageCategory forInvoice(InvoiceMessageSubject invoice) {
    if (invoice.isPaid) return paid;
    if (invoice.isOverdue) return overdue;
    // Partially paid still has money outstanding, so it reads as unpaid.
    return unpaid;
  }

  static InvoiceMessageCategory parse(String? value) {
    return InvoiceMessageCategory.values.firstWhere(
      (c) => c.name == value,
      orElse: () => any,
    );
  }
}

/// A placeholder the user can drop into a template body.
enum InvoiceMessageToken {
  clientName('client_name', 'Client name'),
  invoiceNumber('invoice_number', 'Invoice number'),
  total('total', 'Invoice total'),
  amountDue('amount_due', 'Amount due'),
  invoiceDate('invoice_date', 'Invoice date'),
  dueDate('due_date', 'Due date'),
  bankingDetails('banking_details', 'Banking details'),
  payLink('pay_link', 'Payment link');

  const InvoiceMessageToken(this.key, this.label);

  /// Wire key, written into the body as `{client_name}`.
  final String key;

  /// Human label shown on the insert chips.
  final String label;

  String get placeholder => '{$key}';
}

/// A reusable message body for sharing an invoice over WhatsApp or email.
class InvoiceMessageTemplate {
  final String id;
  final String name;
  final String body;
  final InvoiceMessageCategory category;

  /// Sort order in the picker; ties fall back to [name].
  final int order;

  const InvoiceMessageTemplate({
    required this.id,
    required this.name,
    required this.body,
    this.category = InvoiceMessageCategory.any,
    this.order = 0,
  });

  factory InvoiceMessageTemplate.fromMap(Map<String, dynamic> map) {
    return InvoiceMessageTemplate(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      body: map['body'] as String? ?? '',
      category: InvoiceMessageCategory.parse(map['category'] as String?),
      order: (map['order'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'body': body,
      'category': category.name,
      'order': order,
    };
  }

  /// Whether this template should be offered for [invoice].
  bool appliesTo(InvoiceMessageSubject invoice) =>
      category == InvoiceMessageCategory.any ||
      category == InvoiceMessageCategory.forInvoice(invoice);

  /// Substitute every token with the invoice's values.
  ///
  /// Unknown `{...}` sequences are left untouched — they may be literal text
  /// the user wants, and silently deleting them would be worse than leaving
  /// them visible.
  String render(
    InvoiceMessageSubject invoice, {
    String bankingDetails = '',
  }) {
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final dateFormat = DateFormat('d MMM y');

    String forToken(InvoiceMessageToken t) {
      switch (t) {
        case InvoiceMessageToken.clientName:
          return invoice.clientName;
        case InvoiceMessageToken.invoiceNumber:
          return invoice.invoiceNumber;
        case InvoiceMessageToken.total:
          return currency.format(invoice.total);
        case InvoiceMessageToken.amountDue:
          return currency.format(invoice.amountDue);
        case InvoiceMessageToken.invoiceDate:
          return invoice.date == null ? '' : dateFormat.format(invoice.date!);
        case InvoiceMessageToken.dueDate:
          return invoice.dueDate == null
              ? ''
              : dateFormat.format(invoice.dueDate!);
        case InvoiceMessageToken.bankingDetails:
          return bankingDetails;
        case InvoiceMessageToken.payLink:
          return invoice.payLink;
      }
    }

    var result = body;
    for (final token in InvoiceMessageToken.values) {
      result = result.replaceAll(token.placeholder, forToken(token));
    }
    return result;
  }

  InvoiceMessageTemplate copyWith({
    String? id,
    String? name,
    String? body,
    InvoiceMessageCategory? category,
    int? order,
  }) {
    return InvoiceMessageTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      body: body ?? this.body,
      category: category ?? this.category,
      order: order ?? this.order,
    );
  }
}
