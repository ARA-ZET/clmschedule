import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/xero_invoice.dart';
import '../../services/xero_accounting_service.dart';
import '../../utils/schedule_time.dart';
import '../zoho/invoice_message_settings_dialog.dart';
import '../zoho/zoho_status_chip.dart';
import '../zoho/zoho_table.dart';
import 'xero_invoice_detail_screen.dart';
import 'xero_status_chip.dart';

/// Date windows offered on the invoice list.
///
/// Mirrors Zoho's `ZohoDateRange` so the two screens read alike, but the
/// filtering is expressed very differently: Zoho takes `date_start`/`date_end`
/// parameters, while Xero has no date parameter at all and wants a `where`
/// expression using its own `DateTime(y,m,d)` literal syntax. Applied
/// server-side either way, so the window still holds across pages — filtering
/// locally would only ever see the pages already loaded.
enum XeroDateRange {
  all('All dates'),
  thisMonth('This month'),
  lastMonth('Last month'),
  last90Days('Last 90 days'),
  thisYear('This year');

  const XeroDateRange(this.label);
  final String label;

  /// Anchored to SAST via [scheduleToday] rather than `DateTime.now()`, so a
  /// client in another timezone does not shift the month boundary.
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
          end: DateTime(now.year, 12, 31),
        );
    }
  }

  /// The `where` clause for this window, or null for [all].
  ///
  /// Xero wants `DateTime(2026,08,01)` — its own literal, not an ISO string
  /// and not quoted. The end bound is `<=` on the last day of the window,
  /// which is why [bounds] returns inclusive dates.
  String? get whereClause {
    final b = bounds;
    String lit(DateTime d) => 'DateTime(${d.year},${d.month},${d.day})';

    final parts = [
      if (b.start != null) 'Date >= ${lit(b.start!)}',
      if (b.end != null) 'Date <= ${lit(b.end!)}',
    ];
    return parts.isEmpty ? null : parts.join(' AND ');
  }
}

/// Community Life Media's invoices, read from Xero.
///
/// A body-only view with no Scaffold of its own — it is hosted as a tab inside
/// [XeroAccountingScreen], so the app bar and page background belong to the
/// host.
///
/// Reuses the table chrome built for Zoho (`ZohoTable`, `ZohoPalette` and
/// friends) rather than duplicating ~540 lines. Those widgets are generic
/// despite the name; renaming them to something provider-neutral is a tidy-up
/// tracked in the integration plan, not a blocker.
///
/// State is held here rather than in a provider: this is a read-only list, and
/// the Zoho equivalent's 400-line provider exists mostly to serve the
/// create/edit flows, which Xero does not have yet.
class XeroInvoicesView extends riverpod.ConsumerStatefulWidget {
  const XeroInvoicesView({super.key});

  @override
  riverpod.ConsumerState<XeroInvoicesView> createState() =>
      _XeroInvoicesViewState();
}

class _XeroInvoicesViewState extends riverpod.ConsumerState<XeroInvoicesView>
    with AutomaticKeepAliveClientMixin {
  // Kept alive so switching tabs does not refetch. Every avoidable call
  // matters against a 1,000/day budget.
  @override
  bool get wantKeepAlive => true;

  final _searchController = TextEditingController();

  /// Search refetches from Xero, so it is debounced rather than firing a
  /// request per keystroke. On a 1,000-call daily budget that is not a nicety.
  Timer? _searchDebounce;

  XeroDateRange _dateRange = XeroDateRange.all;

  /// Insertion order is display order — Dart preserves it.
  static const _filterable = <XeroInvoiceStatus?, String>{
    null: 'All Invoices',
    XeroInvoiceStatus.draft: 'Draft',
    XeroInvoiceStatus.submitted: 'Submitted',
    XeroInvoiceStatus.authorised: 'Awaiting payment',
    XeroInvoiceStatus.paid: 'Paid',
    XeroInvoiceStatus.voided: 'Void',
  };

  /// Xero's `order` expression per column. Null means the column is not
  /// sortable server-side, and sorting only the loaded pages locally would
  /// misrepresent the whole set.
  static const _columns = <ZohoColumn>[
    ZohoColumn(label: 'Date', width: 110),
    ZohoColumn(label: 'Invoice#', width: 140),
    ZohoColumn(label: 'Contact', width: 200, flexible: true),
    ZohoColumn(label: 'Status', width: 140, sortable: false),
    ZohoColumn(label: 'Due Date', width: 110),
    ZohoColumn(label: 'Amount', width: 120, alignment: Alignment.centerRight),
    ZohoColumn(label: 'Due', width: 120, alignment: Alignment.centerRight),
  ];

  static const _sortFields = <String?>[
    'Date',
    'InvoiceNumber',
    'Contact.Name',
    null, // Status — Xero cannot order by it usefully
    'DueDate',
    'Total',
    'AmountDue',
  ];

  final List<XeroInvoice> _invoices = [];
  XeroInvoiceStatus? _statusFilter;
  String _searchTerm = '';
  int _sortColumn = 0;
  bool _sortAscending = false;

  int _page = 1;
  bool _hasMore = false;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    assert(_columns.length == _sortFields.length,
        'Sort fields map to columns by index — keep them the same length.');
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  String? get _order {
    final field = _sortFields[_sortColumn];
    if (field == null) return null;
    return '$field ${_sortAscending ? 'ASC' : 'DESC'}';
  }

  /// Bumped by every [_reload]; a fetch that lands after a newer one started
  /// is dropped, so a slow "ab" response cannot overwrite "abc"'s results.
  int _generation = 0;

  /// Contacts whose name matches the current search — resolved on page one
  /// and reused for later pages, so paging costs no extra contact lookups.
  List<String> _searchContactIds = const [];

  /// Bounds the `ContactIDs` list a vague term can produce. It travels in the
  /// query string, and 50 GUIDs is still well inside URL limits.
  static const _maxSearchContacts = 50;

  Future<void> _reload() async {
    _generation++;
    setState(() {
      _isLoading = true;
      _isLoadingMore = false;
      _error = null;
      _page = 1;
    });
    await _fetch(replace: true);
  }

  Future<void> _loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    _page += 1;
    await _fetch(replace: false);
  }

  Future<XeroPage<XeroInvoice>> _listPage({
    String? searchTerm,
    List<String>? contactIds,
  }) {
    return ref.read(xeroAccountingServiceRiverpod).listInvoices(
          statuses: _statusFilter == null ? null : [_statusFilter!],
          searchTerm: searchTerm,
          contactIds: contactIds,
          where: _dateRange.whereClause,
          order: _order,
          // Line items are not shown in the table, and omitting them is what
          // keeps a large page inside the response limit.
          summaryOnly: true,
          page: _page,
          pageSize: 100,
        );
  }

  /// One page of search results.
  ///
  /// Xero's invoice `searchTerm` only looks at InvoiceNumber and Reference —
  /// never the contact — so typing a client's name always came back empty.
  /// The term is therefore also run against Contacts (whose `searchTerm`
  /// covers the name), and those contacts' invoices are fetched by
  /// `ContactIDs` beside the number/reference results. Two invoice calls plus
  /// one contact lookup per search; paging reuses the contact ids.
  Future<({List<XeroInvoice> items, bool hasMore})> _searchPage() async {
    final service = ref.read(xeroAccountingServiceRiverpod);
    if (_page == 1) {
      try {
        final contacts = await service.listContacts(
          searchTerm: _searchTerm,
          // Old clients are archived, but their invoices still need finding.
          includeArchived: true,
          page: 1,
          pageSize: _maxSearchContacts,
        );
        _searchContactIds = contacts.items
            .map((c) => c.contactId)
            .where((id) => id.isNotEmpty)
            .take(_maxSearchContacts)
            .toList();
      } on XeroException {
        // The number/reference branch still works without it.
        _searchContactIds = const [];
      }
    }

    final pages = await Future.wait([
      _listPage(searchTerm: _searchTerm),
      if (_searchContactIds.isNotEmpty)
        _listPage(contactIds: _searchContactIds),
    ]);
    return (
      items: [for (final p in pages) ...p.items],
      hasMore: pages.any((p) => p.hasMore),
    );
  }

  /// Local mirror of [_order], used only to interleave merged search results.
  int _compare(XeroInvoice a, XeroInvoice b) {
    int byDate(DateTime? x, DateTime? y) {
      if (x == null && y == null) return 0;
      if (x == null) return -1;
      if (y == null) return 1;
      return x.compareTo(y);
    }

    final int c;
    switch (_sortColumn) {
      case 1:
        c = a.invoiceNumber.compareTo(b.invoiceNumber);
      case 2:
        c = a.contactName.toLowerCase().compareTo(b.contactName.toLowerCase());
      case 4:
        c = byDate(a.dueDate, b.dueDate);
      case 5:
        c = a.total.compareTo(b.total);
      case 6:
        c = a.amountDue.compareTo(b.amountDue);
      default:
        c = byDate(a.date, b.date);
    }
    return _sortAscending ? c : -c;
  }

  Future<void> _fetch({required bool replace}) async {
    final gen = _generation;
    try {
      final List<XeroInvoice> items;
      final bool hasMore;
      if (_searchTerm.isEmpty) {
        final page = await _listPage();
        items = page.items;
        hasMore = page.hasMore;
      } else {
        final result = await _searchPage();
        items = result.items;
        hasMore = result.hasMore;
      }
      if (!mounted || gen != _generation) return;
      setState(() {
        if (replace) _invoices.clear();
        _invoices.addAll(items);
        if (_searchTerm.isNotEmpty) {
          // Two sources merged — an invoice can match both its number and
          // its contact, so dedupe, then restore the chosen order.
          final seen = <String>{};
          _invoices
            ..retainWhere((i) => seen.add(i.invoiceId))
            ..sort(_compare);
        }
        _hasMore = hasMore;
        _isLoading = false;
        _isLoadingMore = false;
      });
    } on XeroException catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = e.message;
        _isLoading = false;
        _isLoadingMore = false;
        if (!replace) _page -= 1;
      });
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _searchTerm = value.trim();
      _reload();
    });
  }

  void _onSort(int index) {
    setState(() {
      if (_sortColumn == index) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = index;
        _sortAscending = false;
      }
    });
    _reload();
  }

  /// Says which of the three filters is responsible for an empty list, rather
  /// than a bare "No invoices" that reads as "Xero is empty".
  String get _emptyMessage {
    if (_searchTerm.isNotEmpty) return 'No invoices match "$_searchTerm".';
    if (_statusFilter != null) {
      return 'No ${(_filterable[_statusFilter] ?? '').toLowerCase()} invoices'
          '${_dateRange == XeroDateRange.all ? '' : ' in ${_dateRange.label.toLowerCase()}'}.';
    }
    if (_dateRange != XeroDateRange.all) {
      return 'No invoices in ${_dateRange.label.toLowerCase()}.';
    }
    return 'No invoices in Xero yet.';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final dateFormat = DateFormat('d MMM y');

    return ColoredBox(
      color: ZohoPalette.pageBackground,
      child: Column(
        children: [
          ZohoToolbar(
            leading: ZohoFilterDropdown<XeroInvoiceStatus?>(
              value: _statusFilter,
              options: _filterable,
              onChanged: _isLoading
                  ? null
                  : (s) {
                      setState(() => _statusFilter = s);
                      _reload();
                    },
            ),
            actions: [
              ZohoSearchField(
                controller: _searchController,
                hintText: 'Search invoices',
                onChanged: _onSearchChanged,
                showClear: _searchController.text.isNotEmpty,
                onClear: () {
                  _searchDebounce?.cancel();
                  _searchController.clear();
                  _searchTerm = '';
                  _reload();
                },
              ),
              const SizedBox(width: 8),
              ZohoFilterDropdown<XeroDateRange>(
                value: _dateRange,
                icon: Icons.event,
                options: {for (final r in XeroDateRange.values) r: r.label},
                onChanged: _isLoading
                    ? null
                    : (r) {
                        setState(() => _dateRange = r);
                        _reload();
                      },
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                color: ZohoPalette.textMuted,
                tooltip: 'Reload from Xero',
                onPressed: _isLoading ? null : _reload,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined, size: 20),
                color: ZohoPalette.textMuted,
                tooltip: 'Share message templates',
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const InvoiceMessageSettingsDialog(),
                ),
              ),
            ],
          ),
          // A failed refresh keeps the rows it already has and explains itself
          // above them; only an empty list escalates to the full-screen error
          // inside ZohoAsyncBody.
          if (_error != null && _invoices.isNotEmpty)
            _ErrorBanner(message: _error!, onRetry: _reload),
          if (_isLoading && _invoices.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ZohoAsyncBody(
              isLoading: _isLoading,
              error: _invoices.isEmpty ? _error : null,
              isEmpty: _invoices.isEmpty,
              emptyIcon: Icons.receipt_long_outlined,
              emptyMessage: _emptyMessage,
              onRetry: _reload,
              child: ZohoTable(
                columns: _columns,
                rowCount: _invoices.length,
                sortColumnIndex: _sortColumn,
                sortAscending: _sortAscending,
                onSort: _onSort,
                onRowTap: (index) => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => XeroInvoiceDetailScreen(
                      invoiceId: _invoices[index].invoiceId,
                    ),
                  ),
                ),
                onEndReached: _loadMore,
                isLoadingMore: _isLoadingMore,
                hasMore: _hasMore,
                // Status colour on each row, as on the Zoho list: green paid,
                // red overdue, blue awaiting payment, orange part-paid or
                // submitted, grey draft / void.
                rowAccent: (index) => _invoices[index].rowColor,
                rowBuilder: (context, index) {
                  final inv = _invoices[index];
                  final struck = inv.status.isStruckThrough;
                  return [
                    ZohoCellText(
                      inv.date == null ? '' : dateFormat.format(inv.date!),
                      strikeThrough: struck,
                    ),
                    ZohoLinkText(inv.invoiceNumber, strikeThrough: struck),
                    ZohoCellText(inv.contactName, strikeThrough: struck),
                    XeroStatusChip(
                      status: inv.status,
                      isOverdue: inv.isOverdue,
                      dense: true,
                    ),
                    ZohoCellText(
                      inv.dueDate == null
                          ? ''
                          : dateFormat.format(inv.dueDate!),
                      strikeThrough: struck,
                    ),
                    ZohoCellText(currency.format(inv.total),
                        strikeThrough: struck),
                    ZohoCellText(currency.format(inv.amountDue),
                        strikeThrough: struck),
                  ];
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.red.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: const TextStyle(fontSize: 12)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
