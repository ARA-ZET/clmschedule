import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/zoho_customer.dart';
import '../models/zoho_invoice.dart';
import '../models/zoho_item.dart';

/// One client per Zoho Books organisation, keyed by organisation id — see
/// `ZohoOrg` for which company bills through which.
final zohoBooksServiceRiverpod =
    riverpod.Provider.family<ZohoBooksService, String>(
  (ref, organizationId) => ZohoBooksService(organizationId: organizationId),
);

/// Thrown for every Zoho Books failure. The proxy raises an `HttpsError`
/// whenever Zoho's response carries a non-zero `code`, and this wraps it so
/// callers see one exception type instead of Firebase plumbing.
class ZohoBooksException implements Exception {
  final String message;

  /// Zoho's own error code, when the proxy managed to extract one.
  final int? zohoCode;

  /// The callable's status string, e.g. `resource-exhausted` when Zoho
  /// rate-limits us or `permission-denied` when the refresh token is bad.
  final String? status;

  const ZohoBooksException(this.message, {this.zohoCode, this.status});

  /// Zoho rate limits aggressively; worth surfacing differently in the UI.
  bool get isRateLimited => status == 'resource-exhausted';

  /// The OAuth credentials are wrong or revoked — a config problem, not a
  /// transient one, so retrying will not help.
  bool get isAuthFailure => status == 'permission-denied';

  @override
  String toString() => message;
}

/// One page of a Zoho list response, carrying the `page_context.has_more_page`
/// flag so callers can follow pagination instead of silently truncating.
class ZohoPage<T> {
  final List<T> items;
  final bool hasMore;

  const ZohoPage({required this.items, required this.hasMore});
}

/// Client for the Zoho Books API v3.
///
/// Every call goes through the `zohoBooks` Cloud Function rather than talking
/// to Zoho directly: the OAuth client secret and refresh token live as Firebase
/// secrets, and this app ships a web build where anything compiled into the
/// bundle is readable from devtools. Token refresh and the `"code": 0` success
/// check happen server-side — see functions/lib/zoho_books.js.
///
/// Bound to one organisation: [organizationId] rides along on every call, and
/// the proxy checks it is an org the Zoho login can actually reach.
/// A key for one create action — one save flow, one dialog. Every retry
/// and repeated click within that action sends the same key, and the proxy
/// returns the record the first call created instead of making another
/// (functions/lib/zoho_books.js, `runIdempotent`). A new action gets a new
/// key, so deliberately raising a second invoice still works.
String newZohoIdempotencyKey(String kind) {
  final random = Random.secure();
  final suffix = List.generate(
      16, (_) => random.nextInt(36).toRadixString(36)).join();
  return 'clm-$kind-${DateTime.now().millisecondsSinceEpoch}-$suffix';
}

class ZohoBooksService {
  final FirebaseFunctions _functions;
  final String organizationId;

  ZohoBooksService({required this.organizationId, FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Invoke one allowlisted proxy operation.
  Future<Map<String, dynamic>> _call(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    try {
      final result = await _functions.httpsCallable('zohoBooks').call<dynamic>({
        'op': op,
        'organizationId': organizationId,
        ...args,
      });
      return Map<String, dynamic>.from(result.data as Map);
    } on FirebaseFunctionsException catch (e) {
      final details = e.details;
      throw ZohoBooksException(
        e.message ?? 'Zoho Books call "$op" failed.',
        zohoCode: details is Map ? details['zohoCode'] as int? : null,
        status: e.code,
      );
    }
  }

  // ── Organisations ──────────────────────────────────────────────────────────

  /// Every organisation the Zoho login can reach, as (id, name). Not scoped to
  /// [organizationId] — it is how a company's org id is chosen in settings.
  Future<List<({String id, String name})>> listOrganizations() async {
    final data = await _call('listOrganizations');
    final raw = data['organizations'] as List<dynamic>? ?? const [];
    return raw.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return (
        id: '${m['organization_id'] ?? ''}',
        name: '${m['name'] ?? ''}',
      );
    }).toList();
  }

  // ── Customers ──────────────────────────────────────────────────────────────

  /// [idempotencyKey]: see [newZohoIdempotencyKey].
  Future<ZohoCustomer> createCustomer(ZohoCustomer customer,
      {String? idempotencyKey}) async {
    final data = await _call('createCustomer', {
      'contact': customer.toCreateJson(),
      if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
    });
    return ZohoCustomer.fromJson(
        Map<String, dynamic>.from(data['contact'] as Map));
  }

  /// The organisation's item catalogue — its standard services and rates.
  ///
  /// Reads every page. The catalogue is a price list of tens of rows, not a
  /// contact book, so paging it lazily would add machinery for nothing; a
  /// hard page ceiling stops a runaway loop if Zoho ever misreports
  /// `has_more_page`.
  Future<List<ZohoItem>> listItems({String? searchText}) async {
    final all = <ZohoItem>[];
    var page = 1;

    while (page <= 20) {
      final data = await _call('listItems', {
        if (searchText != null && searchText.isNotEmpty)
          'searchText': searchText,
        'page': page,
        'perPage': 200,
      });

      final raw = data['items'] as List<dynamic>? ?? const [];
      all.addAll(raw
          .map((e) => ZohoItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((i) => i.itemId.isNotEmpty));

      final context = data['page_context'] as Map<dynamic, dynamic>?;
      final hasMore = context?['has_more_page'] as bool? ?? false;
      if (!hasMore || raw.isEmpty) break;
      page++;
    }

    return all;
  }

  /// One page of customers. Zoho caps `per_page` at 200 — use
  /// [listAllCustomers] unless you specifically want a single page.
  Future<ZohoPage<ZohoCustomer>> listCustomers({
    String? searchText,
    int? page,
    int? perPage,
  }) async {
    final data = await _call('listCustomers', {
      if (searchText != null && searchText.isNotEmpty) 'searchText': searchText,
      if (page != null) 'page': page,
      if (perPage != null) 'perPage': perPage,
    });
    final contacts = data['contacts'] as List<dynamic>? ?? const [];
    final context = data['page_context'] as Map<dynamic, dynamic>?;
    return ZohoPage(
      items: contacts
          .map(
              (e) => ZohoCustomer.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      hasMore: context?['has_more_page'] as bool? ?? false,
    );
  }

  /// Every customer, following Zoho's pagination.
  ///
  /// The list endpoint returns at most 200 per page, so a single call silently
  /// truncates larger books — which makes client-side search miss anyone past
  /// the first page. [maxPages] bounds the worst case.
  Future<List<ZohoCustomer>> listAllCustomers({
    String? searchText,
    int maxPages = 25,
  }) async {
    final all = <ZohoCustomer>[];
    for (var page = 1; page <= maxPages; page++) {
      final result = await listCustomers(
        searchText: searchText,
        page: page,
        perPage: 200,
      );
      all.addAll(result.items);
      if (!result.hasMore || result.items.isEmpty) break;
    }
    return all;
  }

  /// Full contact including `contact_persons`. The list endpoint omits those,
  /// and [updateCustomer] needs the primary `contact_person_id` to avoid
  /// appending a duplicate contact person.
  Future<ZohoCustomer> getCustomer(String contactId) async {
    final data = await _call('getCustomer', {'contactId': contactId});
    return ZohoCustomer.fromJson(
        Map<String, dynamic>.from(data['contact'] as Map));
  }

  Future<ZohoCustomer> updateCustomer(ZohoCustomer customer) async {
    final data = await _call('updateCustomer', {
      'contactId': customer.contactId,
      'contact': customer.toUpdateJson(),
    });
    return ZohoCustomer.fromJson(
        Map<String, dynamic>.from(data['contact'] as Map));
  }

  // ── Invoices ───────────────────────────────────────────────────────────────

  /// Create an invoice. A non-empty [ZohoInvoice.invoiceNumber] is kept as-is
  /// even when Zoho auto-numbering is switched on.
  /// [idempotencyKey]: see [newZohoIdempotencyKey].
  Future<ZohoInvoice> createInvoice(ZohoInvoice invoice,
      {String? idempotencyKey}) async {
    final data = await _call('createInvoice', {
      'invoice': invoice.toCreateJson(),
      if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
    });
    return ZohoInvoice.fromJson(
        Map<String, dynamic>.from(data['invoice'] as Map));
  }

  Future<ZohoInvoice> updateInvoice(
    String invoiceId,
    Map<String, dynamic> changes,
  ) async {
    final data = await _call('updateInvoice', {
      'invoiceId': invoiceId,
      'invoice': changes,
    });
    return ZohoInvoice.fromJson(
        Map<String, dynamic>.from(data['invoice'] as Map));
  }

  /// The invoice rendered as a PDF by Zoho, using the organisation's own
  /// invoice template — byte-for-byte what Zoho Books prints.
  ///
  /// Transferred base64 because callables carry JSON; a typical invoice is
  /// well under the callable response limit.
  Future<Uint8List> getInvoicePdf(String invoiceId) async {
    final data = await _call('getInvoicePdf', {'invoiceId': invoiceId});
    final encoded = data['pdfBase64'] as String?;
    if (encoded == null || encoded.isEmpty) {
      throw const ZohoBooksException('Zoho returned an empty PDF.');
    }
    return base64Decode(encoded);
  }

  Future<ZohoInvoice> getInvoice(String invoiceId) async {
    final data = await _call('getInvoice', {'invoiceId': invoiceId});
    return ZohoInvoice.fromJson(
        Map<String, dynamic>.from(data['invoice'] as Map));
  }

  Future<ZohoInvoiceStatus> getInvoiceStatus(String invoiceId) async {
    return (await getInvoice(invoiceId)).status;
  }

  /// One page of invoices.
  ///
  /// Filtering, sorting and date-ranging are all done by Zoho, verified
  /// against the live API — which is what lets the screen page through
  /// results without the sort or filters silently applying to only the
  /// loaded slice.
  ///
  /// [sortColumn] accepts `date`, `invoice_number`, `customer_name`,
  /// `due_date`, `total`, `balance`. **`status` is rejected by Zoho** and
  /// must not be passed. [sortOrder] is `A` or `D`.
  Future<ZohoPage<ZohoInvoice>> listInvoices({
    ZohoInvoiceStatus? status,
    String? customerId,
    String? searchText,
    String? sortColumn,
    String? sortOrder,
    DateTime? dateStart,
    DateTime? dateEnd,
    int? page,
    int? perPage,
  }) async {
    final data = await _call('listInvoices', {
      if (status != null) 'status': status.apiValue,
      if (customerId != null && customerId.isNotEmpty) 'customerId': customerId,
      if (searchText != null && searchText.isNotEmpty) 'searchText': searchText,
      if (sortColumn != null && sortColumn.isNotEmpty) 'sortColumn': sortColumn,
      if (sortOrder != null && sortOrder.isNotEmpty) 'sortOrder': sortOrder,
      if (dateStart != null) 'dateStart': ZohoInvoice.formatDate(dateStart),
      if (dateEnd != null) 'dateEnd': ZohoInvoice.formatDate(dateEnd),
      if (page != null) 'page': page,
      if (perPage != null) 'perPage': perPage,
    });
    final invoices = data['invoices'] as List<dynamic>? ?? const [];
    final context = data['page_context'] as Map<dynamic, dynamic>?;
    return ZohoPage(
      items: invoices
          .map((e) => ZohoInvoice.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      hasMore: context?['has_more_page'] as bool? ?? false,
    );
  }

  // Status transitions use Zoho's action endpoints — PUT-ing `status` is
  // silently ignored by the API.

  Future<void> markInvoiceSent(String invoiceId) =>
      _call('markInvoiceSent', {'invoiceId': invoiceId});

  Future<void> voidInvoice(String invoiceId) =>
      _call('voidInvoice', {'invoiceId': invoiceId});

  Future<void> draftInvoice(String invoiceId) =>
      _call('draftInvoice', {'invoiceId': invoiceId});

  /// Mark an invoice paid by recording a payment against it. Zoho has no
  /// "paid" action — the status follows from the payment.
  Future<void> recordPayment({
    required String customerId,
    required String invoiceId,
    required double amount,
    DateTime? date,
    String paymentMode = 'cash',
    String reference = '',
    String? idempotencyKey,
  }) {
    return _call('recordPayment', {
      if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
      'payment': {
        'customer_id': customerId,
        'amount': amount,
        'date': ZohoInvoice.formatDate(date ?? DateTime.now()),
        'payment_mode': paymentMode,
        if (reference.isNotEmpty) 'reference_number': reference,
        'invoices': [
          {'invoice_id': invoiceId, 'amount_applied': amount},
        ],
      },
    });
  }
}
