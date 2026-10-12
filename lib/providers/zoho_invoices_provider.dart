import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/zoho_invoice.dart';
import '../services/job_list_service.dart';
import '../services/zoho_books_service.dart';
import '../utils/schedule_time.dart';
import 'zoho_sync_settings_provider.dart';

/// Keyed by Zoho organisation id, so each organisation's invoice list pages,
/// filters and caches independently.
final zohoInvoicesRiverpod =
    riverpod.ChangeNotifierProvider.family<ZohoInvoicesProvider, String>(
        (ref, orgId) {
  final provider =
      ZohoInvoicesProvider(service: ref.read(zohoBooksServiceRiverpod(orgId)));

  // Wired here rather than inside the provider so it stays free of any
  // dependency on JobListService or the sync settings.
  provider.setJobSyncHandler((invoice) async {
    final settings = ref.read(zohoSyncSettingsRiverpod);
    await ref.read(jobListServiceRiverpod).syncInvoiceStatusToJob(
          zohoInvoiceId: invoice.invoiceId,
          zohoStatus: invoice.status.apiValue,
          statusMap: settings.invoiceStatusMap,
        );
  });

  return provider;
});

/// Sortable invoice columns, in the same order as the table's columns so a
/// header index maps straight onto a value.
enum ZohoInvoiceSort {
  date,
  number,
  customer,
  status,
  dueDate,
  amount,
  balance;

  /// Zoho's `sort_column` name, or null when Zoho cannot sort on it.
  /// Verified against the live API — `status` is rejected with code 2, so the
  /// Status column is not sortable.
  String? get apiColumn {
    switch (this) {
      case date:
        return 'date';
      case number:
        return 'invoice_number';
      case customer:
        return 'customer_name';
      case dueDate:
        return 'due_date';
      case amount:
        return 'total';
      case balance:
        return 'balance';
      case status:
        return null;
    }
  }
}

/// Date windows offered alongside the status filter, applied by Zoho via
/// `date_start` / `date_end` (verified against the live API).
enum ZohoDateRange {
  all('All dates'),
  thisMonth('This month'),
  lastMonth('Last month'),
  last90Days('Last 90 days'),
  thisYear('This year');

  const ZohoDateRange(this.label);
  final String label;

  /// Inclusive bounds passed to Zoho as `date_start` / `date_end`, or nulls
  /// for [all]. Applied server-side so the range still holds across pages —
  /// filtering locally would only ever see the pages already loaded.
  ({DateTime? start, DateTime? end}) get bounds {
    final now = scheduleToday();
    switch (this) {
      case all:
        return (start: null, end: null);
      case thisMonth:
        return (
          start: DateTime(now.year, now.month, 1),
          end: DateTime(now.year, now.month + 1, 0),
        );
      case lastMonth:
        return (
          start: DateTime(now.year, now.month - 1, 1),
          end: DateTime(now.year, now.month, 0),
        );
      case last90Days:
        return (start: now.subtract(const Duration(days: 90)), end: now);
      case thisYear:
        return (
          start: DateTime(now.year, 1, 1),
          end: DateTime(now.year, 12, 31)
        );
    }
  }
}

/// Zoho Books invoices.
///
/// Loads lazily via [initialize] rather than in the constructor — see
/// [ZohoCustomersProvider] for why.
class ZohoInvoicesProvider extends ChangeNotifier {
  final ZohoBooksService _service;

  /// Rows fetched per page. Invoices run into the thousands, so the screen
  /// pages lazily rather than pulling the whole book on open.
  static const int pageSize = 25;

  List<ZohoInvoice> _invoices = [];
  ZohoInvoiceStatus? _statusFilter;
  ZohoDateRange _dateRange = ZohoDateRange.all;
  String _searchText = '';
  ZohoInvoiceSort _sortBy = ZohoInvoiceSort.date;
  bool _sortAscending = false; // newest first, matching Zoho's default
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isInitialized = false;
  String? _error;

  /// Highest page number successfully loaded; 0 means nothing yet.
  int _page = 0;
  bool _hasMore = true;

  ZohoInvoicesProvider({required ZohoBooksService service})
      : _service = service;

  List<ZohoInvoice> get invoices => List.unmodifiable(_invoices);
  ZohoInvoiceStatus? get statusFilter => _statusFilter;
  ZohoDateRange get dateRange => _dateRange;
  String get searchText => _searchText;
  ZohoInvoiceSort get sortBy => _sortBy;
  bool get sortAscending => _sortAscending;
  bool get isLoading => _isLoading;

  /// A further page is being appended — distinct from [isLoading], which is
  /// the initial or post-filter load that clears the list.
  bool get isLoadingMore => _isLoadingMore;

  /// Whether Zoho reports more pages after the ones loaded.
  bool get hasMore => _hasMore;

  bool get isInitialized => _isInitialized;
  String? get error => _error;

  /// The loaded invoices, in the order Zoho returned them.
  ///
  /// Filtering, sorting and searching are all server-side, so this list is
  /// already correct for the current query — no local re-filtering, which
  /// would be wrong anyway now that only some pages are loaded.
  List<ZohoInvoice> get filteredInvoices => invoices;

  /// Sort by [field], toggling direction when it is already the sort field.
  /// Refetches from page one, since Zoho does the ordering.
  Future<void> sortByField(ZohoInvoiceSort field) async {
    // Zoho rejects sort_column=status, so that column is not sortable and the
    // table marks it as such. Ignore rather than silently sorting one page.
    if (field.apiColumn == null) return;

    if (_sortBy == field) {
      _sortAscending = !_sortAscending;
    } else {
      _sortBy = field;
      // Dates and money read most usefully high-to-low first.
      _sortAscending = !(field == ZohoInvoiceSort.date ||
          field == ZohoInvoiceSort.dueDate ||
          field == ZohoInvoiceSort.amount ||
          field == ZohoInvoiceSort.balance);
    }
    await refresh();
  }

  Future<void> setDateRange(ZohoDateRange range) async {
    if (_dateRange == range) return;
    _dateRange = range;
    await refresh();
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    await refresh();
  }

  /// Reload from page one, discarding anything already paged in.
  Future<void> refresh() async {
    final gen = ++_generation;
    _isLoading = true;
    _error = null;
    _page = 0;
    _hasMore = true;
    notifyListeners();

    _invoices = [];
    _isLoadingMore = false;
    await _fetchNextPage();

    // A newer refresh has taken over; it owns the loading flag now.
    if (gen != _generation) return;
    _isLoading = false;
    notifyListeners();
  }

  /// Append the next page. Safe to call repeatedly — it no-ops while a fetch
  /// is in flight or once Zoho reports no more pages.
  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) return;
    final gen = _generation;
    _isLoadingMore = true;
    notifyListeners();

    await _fetchNextPage();

    if (gen != _generation) return;
    _isLoadingMore = false;
    notifyListeners();
  }

  /// Bumped by every [refresh]. A fetch whose generation is stale when it
  /// lands is discarded — otherwise a slow response for "ab" could arrive
  /// after the one for "abc" and overwrite (or pad out) the newer results.
  int _generation = 0;

  /// Customers whose name matches the current search, resolved once per
  /// search term and reused for its later pages.
  List<String> _searchCustomerIds = const [];

  /// How many matching customers a search pulls invoices for. Each is one
  /// extra Zoho call per page, so a vague term cannot fan out unboundedly.
  static const int _maxSearchCustomers = 8;

  Future<void> _fetchNextPage() async {
    final gen = _generation;
    final nextPage = _page + 1;
    try {
      final result = _searchText.isEmpty
          ? await _listPage(page: nextPage)
          : await _searchPage(page: nextPage);
      if (gen != _generation) return;
      _invoices = [..._invoices, ...result.items];
      if (_searchText.isNotEmpty) {
        // Several sources merged — dedupe and put them back in sort order.
        final seen = <String>{};
        _invoices = _invoices.where((i) => seen.add(i.invoiceId)).toList()
          ..sort(_compare);
      }
      _page = nextPage;
      _hasMore = result.hasMore && result.items.isNotEmpty;
      _error = null;
    } on ZohoBooksException catch (e) {
      if (gen != _generation) return;
      _error = e.isRateLimited
          ? 'Zoho rate limit reached — wait a moment and try again.'
          : 'Could not load invoices: ${e.message}';
      _hasMore = false;
      if (kDebugMode) print(_error);
    } catch (e) {
      if (gen != _generation) return;
      _error = 'Could not load invoices: $e';
      _hasMore = false;
      if (kDebugMode) print(_error);
    }
  }

  /// One page of the list with the current filters, optionally narrowed to
  /// one customer or a `search_text`.
  Future<ZohoPage<ZohoInvoice>> _listPage({
    required int page,
    String? customerId,
    String? searchText,
  }) {
    final range = _dateRange.bounds;
    return _service.listInvoices(
      status: _statusFilter,
      customerId: customerId,
      searchText: searchText,
      sortColumn: _sortBy.apiColumn,
      sortOrder: _sortAscending ? 'A' : 'D',
      dateStart: range.start,
      dateEnd: range.end,
      page: page,
      perPage: pageSize,
    );
  }

  /// One page of search results.
  ///
  /// Zoho's invoice `search_text` alone missed invoices staff were plainly
  /// searching for — typing a client's name returned "no invoices". So the
  /// term is also run against the customer list (whose search does match
  /// names), and those customers' invoices are fetched by `customer_id`
  /// alongside the `search_text` results. Status and date filters still
  /// apply to every branch, since each goes through [_listPage].
  Future<ZohoPage<ZohoInvoice>> _searchPage({required int page}) async {
    if (page == 1) {
      try {
        final customers = await _service.listCustomers(
          searchText: _searchText,
          perPage: _maxSearchCustomers,
        );
        _searchCustomerIds = customers.items
            .map((c) => c.contactId)
            .where((id) => id.isNotEmpty)
            .take(_maxSearchCustomers)
            .toList();
      } catch (e) {
        // The invoice-number branch still works without it.
        _searchCustomerIds = const [];
        if (kDebugMode) print('Zoho customer search failed: $e');
      }
    }

    final pages = await Future.wait([
      _listPage(page: page, searchText: _searchText),
      for (final id in _searchCustomerIds) _listPage(page: page, customerId: id),
    ]);
    return ZohoPage(
      items: [for (final p in pages) ...p.items],
      hasMore: pages.any((p) => p.hasMore && p.items.isNotEmpty),
    );
  }

  /// Local mirror of the server-side sort, used only to interleave merged
  /// search results.
  int _compare(ZohoInvoice a, ZohoInvoice b) {
    int byDate(DateTime? x, DateTime? y) {
      if (x == null && y == null) return 0;
      if (x == null) return -1;
      if (y == null) return 1;
      return x.compareTo(y);
    }

    final int c;
    switch (_sortBy) {
      case ZohoInvoiceSort.date:
      case ZohoInvoiceSort.status:
        c = byDate(a.date, b.date);
      case ZohoInvoiceSort.number:
        c = a.invoiceNumber.compareTo(b.invoiceNumber);
      case ZohoInvoiceSort.customer:
        c = a.customerName.toLowerCase().compareTo(b.customerName.toLowerCase());
      case ZohoInvoiceSort.dueDate:
        c = byDate(a.dueDate, b.dueDate);
      case ZohoInvoiceSort.amount:
        c = a.total.compareTo(b.total);
      case ZohoInvoiceSort.balance:
        c = a.balance.compareTo(b.balance);
    }
    return _sortAscending ? c : -c;
  }

  /// Change the status filter. Zoho filters server-side, so this refetches.
  Future<void> setStatusFilter(ZohoInvoiceStatus? status) async {
    if (_statusFilter == status) return;
    _statusFilter = status;
    await refresh();
  }

  /// Search runs on Zoho (`search_text`), so it refetches from page one
  /// rather than filtering the loaded pages. Callers should debounce.
  Future<void> setSearchText(String value) async {
    if (_searchText == value) return;
    _searchText = value;
    await refresh();
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

  /// Apply an edit and merge the result into local state.
  /// Rethrows so the calling form can surface the failure.
  Future<ZohoInvoice> updateInvoice(
    String invoiceId,
    Map<String, dynamic> changes,
  ) async {
    _error = null;
    try {
      final updated = await _service.updateInvoice(invoiceId, changes);
      final index = _invoices.indexWhere((i) => i.invoiceId == invoiceId);
      if (index != -1) {
        _invoices = [..._invoices]..[index] = updated;
      }
      notifyListeners();
      return updated;
    } catch (e) {
      _error = 'Could not update invoice: $e';
      notifyListeners();
      rethrow;
    }
  }

  /// Read one invoice without touching local state.
  ///
  /// Unlike [reloadInvoice], this does not splice the result into the loaded
  /// list — when copying a job the source invoice is only a template, and
  /// inserting it would misrepresent the current filter.
  Future<ZohoInvoice> getInvoiceForCopy(String invoiceId) =>
      _service.getInvoice(invoiceId);

  /// One customer's invoices, newest first.
  ///
  /// Deliberately outside the screen's loaded list: that one is filtered and
  /// paged for the invoices table, and reusing it here would answer "the last
  /// invoice" from whatever happened to be on screen.
  Future<List<ZohoInvoice>> listInvoicesForCustomer(
    String customerId, {
    int limit = 10,
  }) async {
    final page = await _service.listInvoices(
      customerId: customerId,
      sortColumn: 'date',
      sortOrder: 'D',
      perPage: limit,
    );
    return page.items;
  }

  /// The Zoho-rendered PDF for an invoice. Not cached — the invoice can change
  /// between views, and a stale printout is worse than a second's wait.
  Future<Uint8List> getInvoicePdf(String invoiceId) =>
      _service.getInvoicePdf(invoiceId);

  /// Re-fetch one invoice and put it in the loaded list, so a status change
  /// does not force a full list reload.
  ///
  /// **Inserts when the invoice is not already loaded.** It previously replaced
  /// in place and dropped the result otherwise, which was fine while the only
  /// way to reach an invoice was through the list — but the detail screen is
  /// now opened cold from the Job List, where the list is empty. There
  /// [getById] stayed null after the fetch, so the screen re-requested on every
  /// rebuild and span forever, hammering Zoho's rate limit.
  ///
  /// Inserting can put a row into the list that the current server-side filter
  /// would not have returned, until the next reload. That is accepted
  /// deliberately: the alternative — holding the invoice only in the detail
  /// screen — leaves the write actions (void, record payment) reloading into a
  /// list that never shows the change, which is the worse failure.
  Future<ZohoInvoice> reloadInvoice(String invoiceId) async {
    final fresh = await _service.getInvoice(invoiceId);
    final index = _invoices.indexWhere((i) => i.invoiceId == invoiceId);
    if (index != -1) {
      _invoices = [..._invoices]..[index] = fresh;
    } else {
      _invoices = [..._invoices, fresh];
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

  /// Run a status-changing write, refresh that invoice from Zoho, then push
  /// the resulting status back onto the linked job.
  ///
  /// The refresh comes first so the job records the status Zoho actually
  /// settled on — recording a payment can land on `paid` or `partially_paid`
  /// depending on the amount, and guessing would put the wrong value on the
  /// job.
  Future<void> _mutate(String invoiceId, Future<void> Function() write) async {
    _error = null;
    try {
      await write();
      final fresh = await reloadInvoice(invoiceId);
      await _syncStatusToJob(fresh);
    } catch (e) {
      _error = 'Invoice update failed: $e';
      notifyListeners();
      rethrow;
    }
  }

  /// Mirror an invoice's status onto its Job List record.
  ///
  /// Deliberately non-fatal: the invoice change already succeeded in Zoho, so
  /// a failure here must not present as "the update failed". It surfaces as a
  /// warning instead, and the next status change retries it.
  Future<void> _syncStatusToJob(ZohoInvoice invoice) async {
    if (_onSyncToJob == null) return;
    try {
      await _onSyncToJob!(invoice);
    } catch (e) {
      _error = 'Invoice updated in Zoho, but the job could not be updated: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
    }
  }

  /// Injected by the app layer so this provider does not depend on
  /// JobListService or the status-mapping settings directly.
  Future<void> Function(ZohoInvoice invoice)? _onSyncToJob;

  // ignore: use_setters_to_change_properties
  void setJobSyncHandler(Future<void> Function(ZohoInvoice invoice)? handler) {
    _onSyncToJob = handler;
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
