import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/zoho_customer.dart';
import '../models/zoho_invoice.dart';

final zohoBooksServiceRiverpod = riverpod.Provider<ZohoBooksService>(
  (ref) => ZohoBooksService(),
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

/// Client for the Zoho Books API v3.
///
/// Every call goes through the `zohoBooks` Cloud Function rather than talking
/// to Zoho directly: the OAuth client secret and refresh token live as Firebase
/// secrets, and this app ships a web build where anything compiled into the
/// bundle is readable from devtools. Token refresh, the `organization_id`
/// parameter and the `"code": 0` success check all happen server-side — see
/// functions/lib/zoho_books.js.
class ZohoBooksService {
  final FirebaseFunctions _functions;

  ZohoBooksService({FirebaseFunctions? functions})
      : _functions =
            functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Invoke one allowlisted proxy operation.
  Future<Map<String, dynamic>> _call(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    try {
      final result = await _functions
          .httpsCallable('zohoBooks')
          .call<dynamic>({'op': op, ...args});
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

  // ── Customers ──────────────────────────────────────────────────────────────

  Future<ZohoCustomer> createCustomer(ZohoCustomer customer) async {
    final data = await _call('createCustomer', {
      'contact': customer.toCreateJson(),
    });
    return ZohoCustomer.fromJson(
        Map<String, dynamic>.from(data['contact'] as Map));
  }

  Future<List<ZohoCustomer>> listCustomers({
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
    return contacts
        .map((e) => ZohoCustomer.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<ZohoCustomer> updateCustomer(ZohoCustomer customer) async {
    final data = await _call('updateCustomer', {
      'contactId': customer.contactId,
      'contact': customer.toCreateJson(),
    });
    return ZohoCustomer.fromJson(
        Map<String, dynamic>.from(data['contact'] as Map));
  }

  // ── Invoices ───────────────────────────────────────────────────────────────

  /// Create an invoice. A non-empty [ZohoInvoice.invoiceNumber] is kept as-is
  /// even when Zoho auto-numbering is switched on.
  Future<ZohoInvoice> createInvoice(ZohoInvoice invoice) async {
    final data = await _call('createInvoice', {
      'invoice': invoice.toCreateJson(),
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

  Future<ZohoInvoice> getInvoice(String invoiceId) async {
    final data = await _call('getInvoice', {'invoiceId': invoiceId});
    return ZohoInvoice.fromJson(
        Map<String, dynamic>.from(data['invoice'] as Map));
  }

  Future<ZohoInvoiceStatus> getInvoiceStatus(String invoiceId) async {
    return (await getInvoice(invoiceId)).status;
  }

  Future<List<ZohoInvoice>> listInvoices({
    ZohoInvoiceStatus? status,
    String? customerId,
    String? searchText,
    int? page,
    int? perPage,
  }) async {
    final data = await _call('listInvoices', {
      if (status != null) 'status': status.apiValue,
      if (customerId != null && customerId.isNotEmpty) 'customerId': customerId,
      if (searchText != null && searchText.isNotEmpty) 'searchText': searchText,
      if (page != null) 'page': page,
      if (perPage != null) 'perPage': perPage,
    });
    final invoices = data['invoices'] as List<dynamic>? ?? const [];
    return invoices
        .map((e) => ZohoInvoice.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
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
  }) {
    return _call('recordPayment', {
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
