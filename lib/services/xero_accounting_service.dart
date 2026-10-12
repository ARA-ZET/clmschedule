import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/xero_contact.dart';
import '../models/xero_invoice.dart';
import '../models/xero_org.dart';

final xeroAccountingServiceRiverpod = riverpod.Provider<XeroAccountingService>(
  (ref) => XeroAccountingService(),
);

/// Thrown for every Xero failure, so callers see one exception type instead of
/// Firebase plumbing.
class XeroException implements Exception {
  final String message;

  /// The callable's status string, e.g. `resource-exhausted` when Xero
  /// rate-limits us or `failed-precondition` when Xero is not connected.
  final String? status;

  /// Seconds Xero asked us to wait, when it sent a `Retry-After`.
  final int? retryAfterSeconds;

  const XeroException(this.message, {this.status, this.retryAfterSeconds});

  /// Xero's daily budget is only 1,000 calls for an uncertified app, so this
  /// is more reachable than the per-minute limit and worth surfacing plainly.
  bool get isRateLimited => status == 'resource-exhausted';

  /// The OAuth credentials are wrong, revoked, or were never set up. A config
  /// problem, not a transient one — retrying will not help.
  bool get isAuthFailure => status == 'permission-denied';

  /// No Xero connection exists yet. Distinct from an auth failure: the fix is
  /// to run the consent flow, not to check credentials.
  bool get isNotConnected =>
      status == 'failed-precondition' && message.contains('not connected');

  /// Xero requires contact names to be unique across the organisation, and
  /// reports a collision as a validation error rather than a typed code.
  bool get isDuplicateName =>
      message.toLowerCase().contains('contact name must be unique');

  /// Xero refuses to void an invoice once a payment or credit note is applied.
  bool get isVoidRefused =>
      message.toLowerCase().contains('cannot be voided') ||
      message.toLowerCase().contains('payment') && message.toLowerCase().contains('void');

  @override
  String toString() => message;
}

/// One page of a Xero list response.
///
/// Xero reports paging as `{page, pageSize, pageCount, itemCount}` rather than
/// Zoho's `has_more_page` boolean, so [hasMore] is derived.
///
/// **Xero omits the pagination block entirely on `summaryOnly` invoice reads**
/// — verified against the live API: the same request with and without
/// `summaryOnly` returns `pageCount: 16` and no block respectively. Trusting
/// the block alone therefore made `hasMore` permanently false on the invoice
/// list, so it silently showed the first page and nothing else. When the block
/// is missing, a full page of rows is taken to mean another may exist.
class XeroPage<T> {
  final List<T> items;
  final int page;
  final int pageCount;
  final int itemCount;

  /// True when Xero returned a `pagination` block. When false, [hasMore] falls
  /// back to the page-size heuristic.
  final bool hasPagination;

  /// The `pageSize` this page was requested with, for that fallback.
  final int? requestedPageSize;

  const XeroPage({
    required this.items,
    this.page = 1,
    this.pageCount = 1,
    this.itemCount = 0,
    this.hasPagination = false,
    this.requestedPageSize,
  });

  bool get hasMore {
    if (hasPagination) return page < pageCount;
    final size = requestedPageSize;
    // A short page is definitely the last one. A full page might not be, so
    // offering "load more" and finding nothing beats truncating silently.
    return size != null && size > 0 && items.length >= size;
  }

  static XeroPage<T> from<T>(
    Map<String, dynamic> data,
    String key,
    T Function(Map<String, dynamic>) parse, {
    int? requestedPageSize,
  }) {
    final raw = data[key] as List<dynamic>? ?? const [];
    final pagination = data['pagination'] as Map<dynamic, dynamic>?;
    return XeroPage<T>(
      items: raw
          .map((e) => parse(Map<String, dynamic>.from(e as Map)))
          .toList(),
      page: (pagination?['page'] as num?)?.toInt() ?? 1,
      pageCount: (pagination?['pageCount'] as num?)?.toInt() ?? 1,
      itemCount: (pagination?['itemCount'] as num?)?.toInt() ?? raw.length,
      hasPagination: pagination != null,
      requestedPageSize: requestedPageSize,
    );
  }
}

/// Client for the Xero Accounting API 2.0.
///
/// Every call goes through the `xeroAccounting` Cloud Function rather than
/// talking to Xero directly: the OAuth client secret and the rotating refresh
/// token live server-side, and this app ships a web build where anything in the
/// bundle is readable from devtools. Token refresh, the `Xero-Tenant-Id` header
/// and error flattening all happen in the proxy — see
/// functions/lib/xero_accounting.js.
class XeroAccountingService {
  final FirebaseFunctions _functions;

  XeroAccountingService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Invoke one allowlisted proxy operation.
  Future<Map<String, dynamic>> _call(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    try {
      final result = await _functions
          .httpsCallable('xeroAccounting')
          .call<dynamic>({'op': op, ...args});
      return Map<String, dynamic>.from(result.data as Map);
    } on FirebaseFunctionsException catch (e) {
      final details = e.details;
      throw XeroException(
        e.message ?? 'Xero call "$op" failed.',
        status: e.code,
        retryAfterSeconds:
            details is Map ? (details['retryAfterSeconds'] as num?)?.toInt() : null,
      );
    }
  }

  // ── Connection ─────────────────────────────────────────────────────────────

  Future<XeroConnectionStatus> connectionStatus() async {
    return XeroConnectionStatus.fromJson(await _call('connectionStatus'));
  }

  Future<XeroOrganisation> getOrganisation() async {
    final data = await _call('getOrganisation');
    final orgs = data['Organisations'] as List<dynamic>? ?? const [];
    if (orgs.isEmpty) {
      throw const XeroException('Xero returned no organisation.');
    }
    return XeroOrganisation.fromJson(
        Map<String, dynamic>.from(orgs.first as Map));
  }

  // ── Contacts ───────────────────────────────────────────────────────────────

  /// One page of contacts.
  ///
  /// Always prefer [searchTerm] over loading everything. The Zoho path can
  /// afford to pull all 826 customers; on 1,000 calls/day this one cannot.
  Future<XeroPage<XeroContact>> listContacts({
    String? searchTerm,
    String? where,
    String? order,
    bool? includeArchived,
    int? page,
    int? pageSize,
  }) async {
    final effectivePage = pageSize != null && page == null ? 1 : page;
    final data = await _call('listContacts', {
      if (searchTerm != null && searchTerm.isNotEmpty) 'searchTerm': searchTerm,
      if (where != null && where.isNotEmpty) 'where': where,
      if (order != null && order.isNotEmpty) 'order': order,
      if (includeArchived != null) 'includeArchived': includeArchived,
      if (effectivePage != null) 'page': effectivePage,
      if (pageSize != null) 'pageSize': pageSize,
    });
    return XeroPage.from(data, 'Contacts', XeroContact.fromJson,
        requestedPageSize: pageSize);
  }

  Future<XeroContact> getContact(String contactId) async {
    final data = await _call('getContact', {'contactId': contactId});
    return _firstContact(data);
  }

  Future<XeroContact> createContact(
    XeroContact contact, {
    String? idempotencyKey,
  }) async {
    final data = await _call('createContact', {
      'contact': contact.toCreateJson(),
      if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
    });
    return _firstContact(data);
  }

  Future<XeroContact> updateContact(
    XeroContact contact, {
    String? idempotencyKey,
  }) async {
    final data = await _call('updateContact', {
      'contactId': contact.contactId,
      'contact': contact.toUpdateJson(),
      if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
    });
    return _firstContact(data);
  }

  XeroContact _firstContact(Map<String, dynamic> data) {
    final contacts = data['Contacts'] as List<dynamic>? ?? const [];
    if (contacts.isEmpty) {
      throw const XeroException('Xero returned no contact.');
    }
    return XeroContact.fromJson(
        Map<String, dynamic>.from(contacts.first as Map));
  }

  // ── Invoices ───────────────────────────────────────────────────────────────

  /// One page of invoices.
  ///
  /// [summaryOnly] drops line items, which is what keeps a large page inside
  /// the response limit — use it for any list view.
  ///
  /// To refresh many statuses at once, pass [invoiceNumbers] or [contactIds]
  /// with a large [pageSize]: **one call can refresh a whole screen**, where
  /// fetching each invoice individually would spend a fifth of the daily
  /// budget on a single Job List paint.
  Future<XeroPage<XeroInvoice>> listInvoices({
    List<XeroInvoiceStatus>? statuses,
    List<String>? contactIds,
    List<String>? invoiceNumbers,
    String? searchTerm,
    String? where,
    String? order,
    bool summaryOnly = false,
    int? page,
    int? pageSize,
  }) async {
    // Xero ignores `pageSize` unless `page` is also sent — without it the
    // endpoint returns everything and no pagination block at all.
    final effectivePage = pageSize != null && page == null ? 1 : page;
    final data = await _call('listInvoices', {
      if (statuses != null && statuses.isNotEmpty)
        'statuses': statuses.map((s) => s.apiValue).toList(),
      if (contactIds != null && contactIds.isNotEmpty) 'contactIds': contactIds,
      if (invoiceNumbers != null && invoiceNumbers.isNotEmpty)
        'invoiceNumbers': invoiceNumbers,
      if (searchTerm != null && searchTerm.isNotEmpty) 'searchTerm': searchTerm,
      if (where != null && where.isNotEmpty) 'where': where,
      if (order != null && order.isNotEmpty) 'order': order,
      if (summaryOnly) 'summaryOnly': true,
      if (effectivePage != null) 'page': effectivePage,
      if (pageSize != null) 'pageSize': pageSize,
    });
    return XeroPage.from(data, 'Invoices', XeroInvoice.fromJson,
        requestedPageSize: pageSize);
  }

  Future<XeroInvoice> getInvoice(String invoiceId) async {
    final data = await _call('getInvoice', {'invoiceId': invoiceId});
    return _firstInvoice(data);
  }

  Future<XeroInvoiceStatus> getInvoiceStatus(String invoiceId) async {
    return (await getInvoice(invoiceId)).status;
  }

  /// Raise an invoice.
  ///
  /// Defaults to AUTHORISED — live and sendable immediately. The consequence is
  /// that its line items become immutable, so the edit path is void-and-reissue
  /// rather than an in-place amendment.
  ///
  /// Pass a stable [idempotencyKey] derived from the job so a retried save
  /// cannot raise a second invoice.
  Future<XeroInvoice> createInvoice(
    XeroInvoice invoice, {
    XeroInvoiceStatus status = XeroInvoiceStatus.authorised,
    String? idempotencyKey,
  }) async {
    final data = await _call('createInvoice', {
      'invoice': invoice.toCreateJson(status: status),
      if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
    });
    return _firstInvoice(data);
  }

  /// Apply an arbitrary change set. Callers should prefer
  /// [XeroInvoice.toSoftUpdateJson] on an AUTHORISED invoice — sending line
  /// items there is rejected by Xero.
  Future<XeroInvoice> updateInvoice(
    String invoiceId,
    Map<String, dynamic> changes, {
    String? idempotencyKey,
  }) async {
    final data = await _call('updateInvoice', {
      'invoiceId': invoiceId,
      'invoice': changes,
      if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
    });
    return _firstInvoice(data);
  }

  /// Void an invoice. Throws with [XeroException.isVoidRefused] when a payment
  /// or credit note is already allocated.
  Future<XeroInvoice> voidInvoice(
    String invoiceId, {
    String? idempotencyKey,
  }) async {
    final data = await _call('voidInvoice', {
      'invoiceId': invoiceId,
      if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
    });
    return _firstInvoice(data);
  }

  /// Send the invoice from Xero, using the organisation's own email template.
  Future<void> emailInvoice(String invoiceId) =>
      _call('emailInvoice', {'invoiceId': invoiceId});

  /// The invoice rendered as a PDF by Xero, using the organisation's branding
  /// theme — byte-for-byte what Xero prints.
  Future<Uint8List> getInvoicePdf(String invoiceId) async {
    final data = await _call('getInvoicePdf', {'invoiceId': invoiceId});
    final encoded = data['pdfBase64'] as String?;
    if (encoded == null || encoded.isEmpty) {
      throw const XeroException('Xero returned an empty PDF.');
    }
    return base64Decode(encoded);
  }

  /// Xero's customer-facing view/pay link. Safe to send onward; treat it as
  /// public, since anyone holding it can view the invoice.
  Future<String> getOnlineInvoiceUrl(String invoiceId) async {
    final data = await _call('getOnlineInvoiceUrl', {'invoiceId': invoiceId});
    final list = data['OnlineInvoices'] as List<dynamic>? ?? const [];
    if (list.isEmpty) return '';
    final first = Map<String, dynamic>.from(list.first as Map);
    return first['OnlineInvoiceUrl'] as String? ?? '';
  }

  XeroInvoice _firstInvoice(Map<String, dynamic> data) {
    final invoices = data['Invoices'] as List<dynamic>? ?? const [];
    if (invoices.isEmpty) {
      throw const XeroException('Xero returned no invoice.');
    }
    return XeroInvoice.fromJson(
        Map<String, dynamic>.from(invoices.first as Map));
  }

  // ── Payments ───────────────────────────────────────────────────────────────

  /// Mark an invoice paid by recording a payment against it. Like Zoho, Xero
  /// has no "paid" action — the status follows from the payment.
  ///
  /// [accountCode] is the **bank account** the money landed in, not the revenue
  /// account the invoice posts to.
  Future<void> createPayment({
    required String invoiceId,
    required String accountCode,
    required double amount,
    DateTime? date,
    String reference = '',
    String? idempotencyKey,
  }) {
    return _call('createPayment', {
      'payment': {
        'Invoice': {'InvoiceID': invoiceId},
        'Account': {'Code': accountCode},
        'Amount': amount,
        'Date': XeroInvoice.formatDate(date ?? DateTime.now()),
        if (reference.isNotEmpty) 'Reference': reference,
      },
      if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
    });
  }

  // ── Organisation config ────────────────────────────────────────────────────

  /// Revenue accounts, for the sales-account picker.
  Future<List<XeroAccount>> listRevenueAccounts() async {
    final data = await _call('listAccounts');
    final accounts = data['Accounts'] as List<dynamic>? ?? const [];
    final list = accounts
        .map((e) => XeroAccount.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((a) => a.isActive)
        .toList();

    // Trading income first. The callable returns REVENUE, SALES and
    // OTHERINCOME together — a chart may use any of them — but the account a
    // distribution invoice posts to is a trading one, and burying it under
    // "Bad Debts Recovered" and "Insurance Payout" invites the wrong pick.
    int rank(XeroAccount a) {
      switch (a.type.toUpperCase()) {
        case 'SALES':
        case 'REVENUE':
          return 0;
        case 'OTHERINCOME':
          return 1;
        default:
          return 2;
      }
    }

    list.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : a.name.compareTo(b.name);
    });
    return list;
  }

  /// Bank accounts, for the record-payment picker.
  ///
  /// Distinct from [listRevenueAccounts]: a payment posts to the account the
  /// money arrived in, and Xero rejects one made against a revenue account.
  Future<List<XeroAccount>> listBankAccounts() async {
    final data = await _call('listBankAccounts');
    final accounts = data['Accounts'] as List<dynamic>? ?? const [];
    return accounts
        .map((e) => XeroAccount.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((a) => a.isActive)
        .toList();
  }

  /// Every active tax rate on the organisation.
  ///
  /// Returns all of them rather than pre-filtering to `canApplyToRevenue`:
  /// which rates are appropriate for a sales invoice is a UI decision, and an
  /// organisation whose rates all report false would otherwise present an empty
  /// dropdown with nothing to explain it.
  /// Xero's Products & Services catalogue — CLM's standard service rates.
  ///
  /// One call for the whole list: `/Items` takes no paging parameters, and a
  /// service business has tens of items, not thousands. Callers should cache it
  /// rather than re-reading per line — the daily budget is 1,000 calls.
  Future<List<XeroItem>> listItems() async {
    final data = await _call('listItems', const {});
    final raw = data['Items'] as List<dynamic>? ?? const [];
    return raw
        .map((e) => XeroItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((i) => i.code.isNotEmpty)
        .toList();
  }

  Future<List<XeroTaxRate>> listTaxRates() async {
    final data = await _call('listTaxRates');
    final rates = data['TaxRates'] as List<dynamic>? ?? const [];
    return rates
        .map((e) => XeroTaxRate.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((r) => r.isActive)
        .toList();
  }
}
