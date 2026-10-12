import 'package:flutter/material.dart';

/// Xero invoice status.
///
/// Deliberately smaller than Zoho's vocabulary, and different in one way that
/// matters: **Xero has no `OVERDUE` status.** An overdue invoice is simply
/// `AUTHORISED` with a due date in the past and money still owing, so overdue
/// is a computed property of the invoice ([XeroInvoice.isOverdue]) rather than
/// a status. Anything switching on status alone will never see it.
enum XeroInvoiceStatus {
  draft,
  submitted,
  authorised,
  paid,
  voided,
  deleted,
  unknown;

  /// Xero's wire value — uppercase, unlike Zoho's snake_case.
  String get apiValue {
    switch (this) {
      case draft:
        return 'DRAFT';
      case submitted:
        return 'SUBMITTED';
      case authorised:
        return 'AUTHORISED';
      case paid:
        return 'PAID';
      case voided:
        return 'VOIDED';
      case deleted:
        return 'DELETED';
      case unknown:
        return '';
    }
  }

  static XeroInvoiceStatus parse(String? value) {
    switch (value?.toUpperCase()) {
      case 'DRAFT':
        return draft;
      case 'SUBMITTED':
        return submitted;
      case 'AUTHORISED':
        return authorised;
      case 'PAID':
        return paid;
      case 'VOIDED':
        return voided;
      case 'DELETED':
        return deleted;
      default:
        return unknown;
    }
  }

  String get label {
    switch (this) {
      case draft:
        return 'Draft';
      case submitted:
        return 'Submitted';
      case authorised:
        return 'Awaiting payment';
      case paid:
        return 'Paid';
      case voided:
        return 'Void';
      case deleted:
        return 'Deleted';
      case unknown:
        return 'Unknown';
    }
  }

  /// Matched to the Zoho status colours so the two providers read alike in the
  /// same Job List.
  Color get color {
    switch (this) {
      case paid:
        return const Color(0xFF2E9E4F);
      case authorised:
        return const Color(0xFF2B7DE9);
      case submitted:
        return const Color(0xFFE8912D);
      case draft:
      case unknown:
        return const Color(0xFF8A97A4);
      case voided:
      case deleted:
        return const Color(0xFF6B7683);
    }
  }

  bool get isStruckThrough => this == voided || this == deleted;

  /// Whether line items can still be changed.
  ///
  /// Xero only permits line-item edits on DRAFT and SUBMITTED invoices. Because
  /// this integration raises invoices as AUTHORISED, this is false for
  /// essentially every live invoice — which is what forces the void-and-reissue
  /// edit flow rather than an in-place amendment.
  bool get lineItemsAreEditable => this == draft || this == submitted;

  /// Whether the API can still void this invoice. Xero refuses once a payment
  /// or credit note is allocated, which it reports as a validation error.
  bool get canBeVoided => this == authorised;

  /// Whether Xero will serve a customer-facing online invoice link.
  ///
  /// Verified against the live API: DRAFT, AUTHORISED and PAID all return one;
  /// VOIDED and DELETED return HTTP 404. Offering the button on an annulled
  /// invoice would surface "the resource you're looking for cannot be found",
  /// which reads like a broken integration rather than the expected answer.
  bool get hasOnlineInvoice =>
      this == draft || this == authorised || this == paid;
}

/// How line amounts relate to tax.
///
/// Maps directly onto the app's dormant VAT fields: `priceIsInclVat` picks
/// between [inclusive] and [exclusive], and a job type with `chargesVat == false`
/// uses [noTax].
enum XeroLineAmountType {
  exclusive('Exclusive'),
  inclusive('Inclusive'),
  noTax('NoTax');

  const XeroLineAmountType(this.apiValue);
  final String apiValue;

  static XeroLineAmountType parse(String? value) {
    switch (value) {
      case 'Inclusive':
        return inclusive;
      case 'NoTax':
        return noTax;
      default:
        return exclusive;
    }
  }

  /// The type implied by the app's own flags, in one place so the mapping
  /// cannot drift between the create and update paths.
  static XeroLineAmountType forJob({
    required bool chargesVat,
    required bool priceIsInclVat,
  }) {
    if (!chargesVat) return noTax;
    return priceIsInclVat ? inclusive : exclusive;
  }
}

/// A single billable line on a Xero invoice.
class XeroLineItem {
  /// Xero's id for this line. Present on lines read back from an existing
  /// invoice; empty for lines just added.
  final String lineItemId;

  /// Required by Xero on create.
  final String description;

  final double quantity;
  final double unitAmount;

  /// Required by Xero — the revenue account this line posts to. Comes from
  /// `companies/clm.providerConfig.salesAccountCode`.
  final String accountCode;

  /// Overrides the account's default tax treatment. Empty means "use the
  /// account default", which is usually what you want for a NoTax invoice.
  final String taxType;

  /// Links the line to Xero's item catalogue, when it came from one.
  final String itemCode;

  /// Line total as Xero computed it. Read-only.
  final double lineAmount;

  /// Tax on this line as Xero computed it. Read-only.
  final double taxAmount;

  const XeroLineItem({
    this.lineItemId = '',
    required this.description,
    this.quantity = 1.0,
    required this.unitAmount,
    this.accountCode = '',
    this.taxType = '',
    this.itemCode = '',
    this.lineAmount = 0.0,
    this.taxAmount = 0.0,
  });

  factory XeroLineItem.fromJson(Map<String, dynamic> json) {
    return XeroLineItem(
      lineItemId: json['LineItemID'] as String? ?? '',
      description: json['Description'] as String? ?? '',
      quantity: (json['Quantity'] as num?)?.toDouble() ?? 1.0,
      unitAmount: (json['UnitAmount'] as num?)?.toDouble() ?? 0.0,
      accountCode: json['AccountCode'] as String? ?? '',
      taxType: json['TaxType'] as String? ?? '',
      itemCode: json['ItemCode'] as String? ?? '',
      lineAmount: (json['LineAmount'] as num?)?.toDouble() ?? 0.0,
      taxAmount: (json['TaxAmount'] as num?)?.toDouble() ?? 0.0,
    );
  }

  /// How a job's billable units and amount become a line's quantity and unit
  /// price.
  ///
  /// [jobQuantity] is whatever the business actually sells by — man-days for
  /// CLM's distribution work, not the flyer count. The catalogue rate is priced
  /// against the same unit, which is what makes the multiplication mean
  /// something.
  ///
  /// **The two money figures are not the same kind of number**, and conflating
  /// them is how you invoice someone millions. A job's Amount is a *total* for
  /// the whole job; a catalogue item's price is a *rate per unit*. Xero
  /// multiplies quantity by unit amount, so the units may only be carried onto
  /// the line when there is a rate for them to multiply.
  ///
  ///  - A catalogue rate is available → units × rate. This is the case the item
  ///    item list exists for: 3 man-days at R685 each.
  ///  - Only a job total is available → quantity **1**, the total as the unit
  ///    amount. Carrying the units here would multiply a total.
  static ({double quantity, double unitAmount}) lineFigures({
    required double jobQuantity,
    required double jobAmount,
    required double itemUnitPrice,
  }) {
    final qty = jobQuantity > 0 ? jobQuantity : 1.0;

    if (itemUnitPrice > 0) {
      return (quantity: qty, unitAmount: itemUnitPrice);
    }
    if (jobAmount > 0) {
      return (quantity: 1.0, unitAmount: jobAmount);
    }
    return (quantity: qty, unitAmount: 0.0);
  }

  /// Our own view of the line total, for pre-submit display. Xero's
  /// [lineAmount] is authoritative once the invoice exists.
  double get amount => unitAmount * quantity;

  /// [forUpdate] includes `LineItemID`.
  ///
  /// Two Xero rules ride on this. The LineItems array **replaces** the existing
  /// one — any line left out is deleted — and a line sent without its
  /// `LineItemID` is treated as new, so the old one is dropped and a
  /// replacement created, losing its identity on the invoice.
  Map<String, dynamic> toJson({bool forUpdate = false}) {
    return {
      if (forUpdate && lineItemId.isNotEmpty) 'LineItemID': lineItemId,
      'Description': description,
      'Quantity': quantity,
      'UnitAmount': unitAmount,
      if (accountCode.isNotEmpty) 'AccountCode': accountCode,
      if (taxType.isNotEmpty) 'TaxType': taxType,
      if (itemCode.isNotEmpty) 'ItemCode': itemCode,
    };
  }

  XeroLineItem copyWith({
    String? description,
    double? quantity,
    double? unitAmount,
    String? accountCode,
    String? taxType,
    String? itemCode,
  }) {
    return XeroLineItem(
      lineItemId: lineItemId,
      description: description ?? this.description,
      quantity: quantity ?? this.quantity,
      unitAmount: unitAmount ?? this.unitAmount,
      accountCode: accountCode ?? this.accountCode,
      taxType: taxType ?? this.taxType,
      itemCode: itemCode ?? this.itemCode,
      lineAmount: lineAmount,
      taxAmount: taxAmount,
    );
  }
}

/// A Xero accounts-receivable (ACCREC) invoice.
class XeroInvoice {
  final String invoiceId;

  /// Assigned by Xero on create unless supplied.
  final String invoiceNumber;

  final String contactId;
  final String contactName;
  final XeroInvoiceStatus status;
  final DateTime? date;
  final DateTime? dueDate;

  /// Our own reference, printed on the invoice. Used to carry the job link.
  final String reference;

  final double total;
  final double subTotal;
  final double totalTax;

  /// Still owing. Zero on a paid invoice.
  final double amountDue;

  final double amountPaid;
  final String currencyCode;
  final XeroLineAmountType lineAmountTypes;
  final List<XeroLineItem> lineItems;

  /// Xero's own last-modified stamp, for staleness checks.
  final DateTime? updatedDateUtc;

  const XeroInvoice({
    this.invoiceId = '',
    this.invoiceNumber = '',
    required this.contactId,
    this.contactName = '',
    this.status = XeroInvoiceStatus.unknown,
    this.date,
    this.dueDate,
    this.reference = '',
    this.total = 0.0,
    this.subTotal = 0.0,
    this.totalTax = 0.0,
    this.amountDue = 0.0,
    this.amountPaid = 0.0,
    this.currencyCode = '',
    this.lineAmountTypes = XeroLineAmountType.exclusive,
    this.lineItems = const [],
    this.updatedDateUtc,
  });

  factory XeroInvoice.fromJson(Map<String, dynamic> json) {
    final contact = json['Contact'] as Map<dynamic, dynamic>?;
    return XeroInvoice(
      invoiceId: json['InvoiceID'] as String? ?? '',
      invoiceNumber: json['InvoiceNumber'] as String? ?? '',
      contactId: contact?['ContactID'] as String? ?? '',
      contactName: contact?['Name'] as String? ?? '',
      status: XeroInvoiceStatus.parse(json['Status'] as String?),
      date: parseXeroDate(json['DateString'] ?? json['Date']),
      dueDate: parseXeroDate(json['DueDateString'] ?? json['DueDate']),
      reference: json['Reference'] as String? ?? '',
      total: (json['Total'] as num?)?.toDouble() ?? 0.0,
      subTotal: (json['SubTotal'] as num?)?.toDouble() ?? 0.0,
      totalTax: (json['TotalTax'] as num?)?.toDouble() ?? 0.0,
      amountDue: (json['AmountDue'] as num?)?.toDouble() ?? 0.0,
      amountPaid: (json['AmountPaid'] as num?)?.toDouble() ?? 0.0,
      currencyCode: json['CurrencyCode'] as String? ?? '',
      lineAmountTypes:
          XeroLineAmountType.parse(json['LineAmountTypes'] as String?),
      lineItems: (json['LineItems'] as List<dynamic>?)
              ?.map((e) =>
                  XeroLineItem.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      updatedDateUtc: parseXeroDate(json['UpdatedDateUTC']),
    );
  }

  /// Parse a Xero date, in either format it uses.
  ///
  /// Xero's JSON mixes two representations **in the same response**: the .NET
  /// epoch form `/Date(1552262400000+0000)/` for `Date`, `DueDate` and
  /// `UpdatedDateUTC`, and a plain ISO string in the parallel `DateString` /
  /// `DueDateString` fields. Reading only one of them silently yields null
  /// dates on half the payloads, so this handles both.
  static DateTime? parseXeroDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is! String || value.isEmpty) return null;

    final dotNet = RegExp(r'^/Date\((-?\d+)([+-]\d{4})?\)/$').firstMatch(value);
    if (dotNet != null) {
      final millis = int.tryParse(dotNet.group(1)!);
      if (millis == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
    }

    return DateTime.tryParse(value);
  }

  /// Xero expects "yyyy-MM-dd" on write.
  static String formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  /// Overdue is derived, not a status — Xero has no OVERDUE state.
  bool get isOverdue {
    if (status != XeroInvoiceStatus.authorised) return false;
    if (amountDue <= 0) return false;
    final due = dueDate;
    if (due == null) return false;
    final today = DateTime.now();
    return due.isBefore(DateTime(today.year, today.month, today.day));
  }

  /// The colour a list row is tinted with — the status colour, refined by
  /// the two states Xero derives rather than stores, so the list reads like
  /// Zoho's: red overdue, orange part-paid.
  Color get rowColor {
    if (isOverdue) return const Color(0xFFE03E3E);
    if (status == XeroInvoiceStatus.authorised && amountPaid > 0) {
      return const Color(0xFFE8912D);
    }
    return status.color;
  }

  /// Payload for POST /Invoices.
  Map<String, dynamic> toCreateJson({
    XeroInvoiceStatus status = XeroInvoiceStatus.authorised,
  }) {
    return {
      ..._toJson(forUpdate: false),
      'Status': status.apiValue,
    };
  }

  /// Payload for POST /Invoices/{id}.
  ///
  /// Carries `LineItemID` on each line so existing lines are amended rather
  /// than replaced. Only usable while [XeroInvoiceStatus.lineItemsAreEditable];
  /// for an AUTHORISED invoice use [toSoftUpdateJson] or void and reissue.
  Map<String, dynamic> toUpdateJson() => {
        'InvoiceID': invoiceId,
        ..._toJson(forUpdate: true),
      };

  /// The subset Xero accepts on an AUTHORISED invoice with no payments —
  /// no line items, so nothing here can change the amount.
  Map<String, dynamic> toSoftUpdateJson() {
    return {
      'InvoiceID': invoiceId,
      if (reference.isNotEmpty) 'Reference': reference,
      if (dueDate != null) 'DueDate': formatDate(dueDate!),
      if (contactId.isNotEmpty) 'Contact': {'ContactID': contactId},
    };
  }

  Map<String, dynamic> _toJson({required bool forUpdate}) {
    return {
      'Type': 'ACCREC',
      'Contact': {'ContactID': contactId},
      if (invoiceNumber.isNotEmpty) 'InvoiceNumber': invoiceNumber,
      if (reference.isNotEmpty) 'Reference': reference,
      if (date != null) 'Date': formatDate(date!),
      if (dueDate != null) 'DueDate': formatDate(dueDate!),
      if (currencyCode.isNotEmpty) 'CurrencyCode': currencyCode,
      'LineAmountTypes': lineAmountTypes.apiValue,
      'LineItems':
          lineItems.map((e) => e.toJson(forUpdate: forUpdate)).toList(),
    };
  }

  XeroInvoice copyWith({
    String? invoiceId,
    String? invoiceNumber,
    String? contactId,
    String? contactName,
    XeroInvoiceStatus? status,
    DateTime? date,
    DateTime? dueDate,
    String? reference,
    XeroLineAmountType? lineAmountTypes,
    List<XeroLineItem>? lineItems,
  }) {
    return XeroInvoice(
      invoiceId: invoiceId ?? this.invoiceId,
      invoiceNumber: invoiceNumber ?? this.invoiceNumber,
      contactId: contactId ?? this.contactId,
      contactName: contactName ?? this.contactName,
      status: status ?? this.status,
      date: date ?? this.date,
      dueDate: dueDate ?? this.dueDate,
      reference: reference ?? this.reference,
      total: total,
      subTotal: subTotal,
      totalTax: totalTax,
      amountDue: amountDue,
      amountPaid: amountPaid,
      currencyCode: currencyCode,
      lineAmountTypes: lineAmountTypes ?? this.lineAmountTypes,
      lineItems: lineItems ?? this.lineItems,
      updatedDateUtc: updatedDateUtc,
    );
  }
}
