import 'package:cloud_firestore/cloud_firestore.dart';

/// One invoice raised for a job, as the job remembers it.
///
/// A job's **primary** invoice still lives on the flat `accounting*` / `zoho*`
/// fields of [JobListItem] — every existing reader, sync and void flow keys off
/// those, and moving them would be a migration for no gain. This model carries
/// the **split** invoices: the extra ones raised when two or more clients share
/// a job and each is billed for their part (`JobListItem.splitInvoices`).
///
/// [JobListItem.allInvoices] presents both through this one shape, so display
/// code never has to know which kind it is looking at.
///
/// Like the primary fields, [status] is a cache for display. The provider is
/// the source of truth; re-read before acting on it.
class JobInvoiceLink {
  /// `zoho` or `xero` — matches `AccountingProvider.name`.
  final String providerId;

  final String contactId;

  /// Customer name on the invoice. Kept because split invoices go to
  /// *different* customers, and a list of bare numbers would not say which
  /// client owes which.
  final String contactName;

  final String invoiceId;
  final String invoiceNumber;

  /// Provider status wire value — lowercase for Zoho, uppercase for Xero.
  final String status;

  /// Total excluding tax, as the provider computed it.
  final double subTotal;

  /// Total including tax, as the provider computed it.
  final double total;

  final DateTime? syncedAt;

  /// True for the job's primary invoice when presented through
  /// [JobListItem.allInvoices]. Never stored — split entries are always false.
  final bool isPrimary;

  const JobInvoiceLink({
    required this.providerId,
    this.contactId = '',
    this.contactName = '',
    required this.invoiceId,
    required this.invoiceNumber,
    this.status = '',
    this.subTotal = 0.0,
    this.total = 0.0,
    this.syncedAt,
    this.isPrimary = false,
  });

  factory JobInvoiceLink.fromMap(Map<String, dynamic> data) {
    return JobInvoiceLink(
      providerId: data['providerId'] as String? ?? '',
      contactId: data['contactId'] as String? ?? '',
      contactName: data['contactName'] as String? ?? '',
      invoiceId: data['invoiceId'] as String? ?? '',
      invoiceNumber: data['invoiceNumber'] as String? ?? '',
      status: data['status'] as String? ?? '',
      subTotal: (data['subTotal'] as num?)?.toDouble() ?? 0.0,
      total: (data['total'] as num?)?.toDouble() ?? 0.0,
      syncedAt: data['syncedAt'] is Timestamp
          ? (data['syncedAt'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'providerId': providerId,
      if (contactId.isNotEmpty) 'contactId': contactId,
      if (contactName.isNotEmpty) 'contactName': contactName,
      'invoiceId': invoiceId,
      'invoiceNumber': invoiceNumber,
      'status': status,
      'subTotal': subTotal,
      'total': total,
      if (syncedAt != null) 'syncedAt': Timestamp.fromDate(syncedAt!),
    };
  }

  JobInvoiceLink copyWith({
    String? status,
    DateTime? syncedAt,
  }) {
    return JobInvoiceLink(
      providerId: providerId,
      contactId: contactId,
      contactName: contactName,
      invoiceId: invoiceId,
      invoiceNumber: invoiceNumber,
      status: status ?? this.status,
      subTotal: subTotal,
      total: total,
      syncedAt: syncedAt ?? this.syncedAt,
      isPrimary: isPrimary,
    );
  }
}
