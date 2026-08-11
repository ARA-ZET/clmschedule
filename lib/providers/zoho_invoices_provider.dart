import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/zoho_invoice.dart';
import '../services/zoho_books_service.dart';

final zohoInvoicesRiverpod =
    riverpod.ChangeNotifierProvider<ZohoInvoicesProvider>(
  (ref) => ZohoInvoicesProvider(service: ref.read(zohoBooksServiceRiverpod)),
);

/// Zoho Books invoices.
///
/// Loads lazily via [initialize] rather than in the constructor — see
/// [ZohoCustomersProvider] for why.
class ZohoInvoicesProvider extends ChangeNotifier {
  final ZohoBooksService _service;

  List<ZohoInvoice> _invoices = [];
  ZohoInvoiceStatus? _statusFilter;
  String _searchText = '';
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;

  ZohoInvoicesProvider({required ZohoBooksService service})
      : _service = service;

  List<ZohoInvoice> get invoices => List.unmodifiable(_invoices);
  ZohoInvoiceStatus? get statusFilter => _statusFilter;
  String get searchText => _searchText;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String? get error => _error;

  /// Invoices matching the local text search. The status filter is applied
  /// server-side by Zoho (`?status=`), so it is not re-applied here.
  List<ZohoInvoice> get filteredInvoices {
    if (_searchText.isEmpty) return invoices;
    final needle = _searchText.toLowerCase();
    return _invoices
        .where((i) =>
            i.invoiceNumber.toLowerCase().contains(needle) ||
            i.customerName.toLowerCase().contains(needle) ||
            i.referenceNumber.toLowerCase().contains(needle))
        .toList();
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    await refresh();
  }

  Future<void> refresh() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _invoices = await _service.listInvoices(
        status: _statusFilter,
        perPage: 200,
      );
    } on ZohoBooksException catch (e) {
      _error = e.isRateLimited
          ? 'Zoho rate limit reached — wait a moment and try again.'
          : 'Could not load invoices: ${e.message}';
      if (kDebugMode) print(_error);
    } catch (e) {
      _error = 'Could not load invoices: $e';
      if (kDebugMode) print(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Change the status filter. Zoho filters server-side, so this refetches.
  Future<void> setStatusFilter(ZohoInvoiceStatus? status) async {
    if (_statusFilter == status) return;
    _statusFilter = status;
    notifyListeners();
    await refresh();
  }

  void setSearchText(String value) {
    if (_searchText == value) return;
    _searchText = value;
    notifyListeners();
  }

  ZohoInvoice? getById(String invoiceId) {
    for (final i in _invoices) {
      if (i.invoiceId == invoiceId) return i;
    }
    return null;
  }

  /// Create an invoice and merge the result into local state.
  /// Rethrows so the calling form can surface the failure.
  Future<ZohoInvoice> createInvoice(ZohoInvoice invoice) async {
    _error = null;
    try {
      final created = await _service.createInvoice(invoice);
      _invoices = [created, ..._invoices];
      notifyListeners();
      return created;
    } catch (e) {
      _error = 'Could not create invoice: $e';
      notifyListeners();
      rethrow;
    }
  }

  /// Re-fetch one invoice and replace it in place, so a status change does not
  /// force a full list reload.
  Future<ZohoInvoice> reloadInvoice(String invoiceId) async {
    final fresh = await _service.getInvoice(invoiceId);
    final index = _invoices.indexWhere((i) => i.invoiceId == invoiceId);
    if (index != -1) {
      _invoices = [..._invoices]..[index] = fresh;
    }
    notifyListeners();
    return fresh;
  }

  Future<void> markSent(String invoiceId) =>
      _mutate(invoiceId, () => _service.markInvoiceSent(invoiceId));

  Future<void> voidInvoice(String invoiceId) =>
      _mutate(invoiceId, () => _service.voidInvoice(invoiceId));

  Future<void> moveToDraft(String invoiceId) =>
      _mutate(invoiceId, () => _service.draftInvoice(invoiceId));

  /// Record a payment. Zoho has no "mark paid" action — the status follows
  /// from the payment, so the invoice is reloaded afterwards.
  Future<void> recordPayment({
    required String invoiceId,
    required String customerId,
    required double amount,
    DateTime? date,
    String paymentMode = 'cash',
    String reference = '',
  }) {
    return _mutate(
      invoiceId,
      () => _service.recordPayment(
        invoiceId: invoiceId,
        customerId: customerId,
        amount: amount,
        date: date,
        paymentMode: paymentMode,
        reference: reference,
      ),
    );
  }

  /// Run a status-changing write then refresh that invoice from Zoho, so the
  /// UI shows the status Zoho actually settled on rather than an assumed one.
  Future<void> _mutate(String invoiceId, Future<void> Function() write) async {
    _error = null;
    try {
      await write();
      await reloadInvoice(invoiceId);
    } catch (e) {
      _error = 'Invoice update failed: $e';
      notifyListeners();
      rethrow;
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
