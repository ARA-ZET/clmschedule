import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/xero_invoice.dart';
import '../../services/xero_accounting_service.dart';
import '../../services/xero_amount_search.dart';
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

typedef _AmountResult = ({
  List<XeroInvoice> items,
  Map<String, XeroAmountMatch> matches,
  _AmountSummary summary,
});

/// [amount] is set only on page one of an amount search.
typedef _SearchResult = ({
  List<XeroInvoice> items,
  bool hasMore,
  _AmountResult? amount,
});

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

  /// Appended while an amount search has matches: says which figure matched,
  /// e.g. "Line 2 · Flyer drop" — the reason to allocate the payment there.
  /// Last, so the sort fields still line up with the columns by index.
  static const _matchColumn =
      ZohoColumn(label: 'Matched on', width: 240, sortable: false);

  static const _overdueRed = Color(0xFFE03E3E);

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

  /// Set when the search term reads as money — see [XeroAmountSearch].
  int? _amountCents;

  /// Why each amount-matched invoice matched, keyed by invoice id. Shown in
  /// the extra column and used to float those rows to the top.
  final Map<String, XeroAmountMatch> _amountMatches = {};

  /// Invoices read *with* their line items, for matching an amount against
  /// lines and line combinations — Xero's `where` cannot see inside lines.
  /// Read once per status/date window and reused for every amount typed, so
  /// trying "1250", then "1437.50", costs nothing more. [_refresh] drops it.
  List<XeroInvoice>? _lineScan;
  String? _lineScanKey;
  bool _lineScanTruncated = false;

  /// Full invoices are heavy, so the scan stops after this many pages of 100.
  static const _lineScanMaxPages = 10;

  /// What the last amount search checked and found, check by check.
  _AmountSummary? _amountSummary;

  /// Whether the summary banner above results is showing every check.
  bool _amountDetailsOpen = false;

  /// Statuses whose lines are scanned. Unless the user picked one, only
  /// invoices still awaiting payment — the only ones a payment can be
  /// allocated to.
  List<XeroInvoiceStatus> get _lineScanStatuses =>
      _statusFilter == null ? const [XeroInvoiceStatus.authorised] : [_statusFilter!];

  /// Reload button: also re-reads line items, which may have changed in Xero.
  void _refresh() {
    _lineScan = null;
    _lineScanKey = null;
    _reload();
  }

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
    String? amountWhere,
    bool summaryOnly = true,
  }) {
    final where = [_dateRange.whereClause, amountWhere]
        .whereType<String>()
        .join(' AND ');
    return ref.read(xeroAccountingServiceRiverpod).listInvoices(
          statuses: _statusFilter == null ? null : [_statusFilter!],
          searchTerm: searchTerm,
          contactIds: contactIds,
          where: where.isEmpty ? null : where,
          order: _order,
          // Line items are not shown in the table, and omitting them is what
          // keeps a large page inside the response limit.
          summaryOnly: summaryOnly,
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
  ///
  /// A term that reads as money ("1250", "R 1 437,50") is also run as an
  /// amount search, on page one only, since it is complete in one go. The
  /// number/reference search still runs beside it — "9431" may be INV-9431.
  Future<_SearchResult> _searchPage() async {
    final service = ref.read(xeroAccountingServiceRiverpod);
    final cents = _amountCents;
    if (_page == 1 && cents != null) {
      // A contact named in digits is not worth a call.
      _searchContactIds = const [];
      final (text, amount) = await (
        _listPage(searchTerm: _searchTerm),
        _amountSearch(cents),
      ).wait;
      return (
        items: [...amount.items, ...text.items],
        hasMore: text.hasMore,
        amount: (
          items: amount.items,
          matches: amount.matches,
          summary: amount.summary.withText(text.items.length, text.hasMore),
        ),
      );
    }
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
      amount: null,
    );
  }

  /// Invoices matching [cents] on their total, amount due or amount paid
  /// (server-side, every status in the filter), or on a line or combination
  /// of lines (the cached [_lineScan]).
  ///
  /// Each half fails on its own: the other still answers, and the summary
  /// says what could not be checked.
  Future<_AmountResult> _amountSearch(int cents) async {
    String? totalsError;
    String? scanError;

    Future<List<XeroInvoice>> totals() async {
      try {
        final page = await _listPage(
          amountWhere: XeroAmountSearch.whereClause(cents),
          // Xero refuses a Total/AmountDue filter alongside summaryOnly. The
          // filter keeps the result small, so full invoices are affordable.
          summaryOnly: false,
        );
        return page.items;
      } on XeroException catch (e) {
        totalsError = e.message;
        return const [];
      }
    }

    Future<List<XeroInvoice>> lines() async {
      try {
        return await _scanLines();
      } on XeroException catch (e) {
        scanError = e.message;
        return const [];
      }
    }

    final (found, scanned) = await (totals(), lines()).wait;

    // Scanned copies first: they carry line items, and the dedupe in
    // [_fetch] keeps the first copy of each invoice.
    final matches = <String, XeroAmountMatch>{};
    final items = <XeroInvoice>[];
    for (final inv in [...scanned, ...found]) {
      final m = XeroAmountSearch.match(inv, cents) ??
          // Xero matched it, so trust that even if our rounding disagrees.
          (found.contains(inv) ? const XeroAmountMatch('Amount', 2) : null);
      if (m == null) continue;
      items.add(inv);
      final existing = matches[inv.invoiceId];
      if (existing == null || m.rank < existing.rank) {
        matches[inv.invoiceId] = m;
      }
    }

    final summary = _AmountSummary(
      cents: cents,
      statusLabel: _filterable[_statusFilter] ?? '',
      dateLabel: _dateRange.label,
      allStatuses: _statusFilter == null,
      allDates: _dateRange == XeroDateRange.all,
      totalsMatches: matches.values.where((m) => m.rank < 3).length,
      totalsError: totalsError,
      scanStatusWord: _statusFilter == null
          ? 'awaiting-payment'
          : (_filterable[_statusFilter] ?? '').toLowerCase(),
      scannedInvoices: scanned.length,
      scannedLines: scanned.fold(0, (n, inv) => n + inv.lineItems.length),
      scanTruncated: _lineScanTruncated,
      scanError: scanError,
      lineMatches: matches.values.where((m) => m.rank >= 3).length,
      nearMisses: matches.isEmpty
          ? XeroAmountSearch.nearMisses([...scanned, ...found], cents)
          : const [],
    );

    return (items: items, matches: matches, summary: summary);
  }

  /// Invoices in the current status/date window, with their line items.
  /// Newest first, so a truncated scan still covers recent invoices.
  Future<List<XeroInvoice>> _scanLines() async {
    final key = '${_lineScanStatuses.map((s) => s.name).join(',')}'
        '|${_dateRange.name}';
    if (_lineScan != null && _lineScanKey == key) return _lineScan!;

    final service = ref.read(xeroAccountingServiceRiverpod);
    final out = <XeroInvoice>[];
    var truncated = false;
    for (var page = 1;; page++) {
      final result = await service.listInvoices(
        statuses: _lineScanStatuses,
        where: _dateRange.whereClause,
        order: 'Date DESC',
        page: page,
        pageSize: 100,
      );
      out.addAll(result.items);
      if (!result.hasMore) break;
      if (page >= _lineScanMaxPages) {
        truncated = true;
        break;
      }
    }
    _lineScan = out;
    _lineScanKey = key;
    _lineScanTruncated = truncated;
    return out;
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
      _AmountResult? amount;
      if (_searchTerm.isEmpty) {
        final page = await _listPage();
        items = page.items;
        hasMore = page.hasMore;
      } else {
        final result = await _searchPage();
        items = result.items;
        hasMore = result.hasMore;
        amount = result.amount;
      }
      if (!mounted || gen != _generation) return;
      setState(() {
        if (replace) {
          _invoices.clear();
          _amountMatches.clear();
          _amountSummary = null;
        }
        if (amount != null) {
          _amountMatches.addAll(amount.matches);
          _amountSummary = amount.summary;
        }
        _invoices.addAll(items);
        if (_searchTerm.isNotEmpty) {
          // Sources merged — an invoice can match its number, its contact
          // and an amount, so dedupe, then restore the chosen order. Amount
          // matches lead, best match first: they are what was asked for.
          final seen = <String>{};
          _invoices
            ..retainWhere((i) => seen.add(i.invoiceId))
            ..sort((a, b) {
              final ma = _amountMatches[a.invoiceId];
              final mb = _amountMatches[b.invoiceId];
              if (ma != null && mb != null && ma.rank != mb.rank) {
                return ma.rank.compareTo(mb.rank);
              }
              if ((ma == null) != (mb == null)) return ma == null ? 1 : -1;
              return _compare(a, b);
            });
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
      _amountCents = XeroAmountSearch.parseCents(_searchTerm);
      _reload();
    });
  }

  void _openInvoice(String invoiceId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => XeroInvoiceDetailScreen(invoiceId: invoiceId),
      ),
    );
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
    final showMatches = _amountMatches.isNotEmpty;
    final summary = _amountSummary;
    final amountPanel = summary == null
        ? null
        : _AmountSearchPanel(
            summary: summary,
            // With no rows there is nothing else to look at, so show it all.
            expanded: _invoices.isEmpty || _amountDetailsOpen,
            onToggle: _invoices.isEmpty
                ? null
                : () =>
                    setState(() => _amountDetailsOpen = !_amountDetailsOpen),
            onAllStatuses: _isLoading || summary.allStatuses
                ? null
                : () {
                    setState(() => _statusFilter = null);
                    _reload();
                  },
            onAllDates: _isLoading || summary.allDates
                ? null
                : () {
                    setState(() => _dateRange = XeroDateRange.all);
                    _reload();
                  },
            onOpenInvoice: _openInvoice,
          );

    final statusFilter = ZohoFilterDropdown<XeroInvoiceStatus?>(
      value: _statusFilter,
      options: _filterable,
      onChanged: _isLoading
          ? null
          : (s) {
              setState(() => _statusFilter = s);
              _reload();
            },
    );
    final search = ZohoSearchField(
      controller: _searchController,
      hintText: 'Search invoices or an amount',
      onChanged: _onSearchChanged,
      showClear: _searchController.text.isNotEmpty,
      onClear: () {
        _searchDebounce?.cancel();
        _searchController.clear();
        _searchTerm = '';
        _amountCents = null;
        _reload();
      },
    );
    final dateFilter = ZohoFilterDropdown<XeroDateRange>(
      value: _dateRange,
      icon: Icons.event,
      options: {for (final r in XeroDateRange.values) r: r.label},
      onChanged: _isLoading
          ? null
          : (r) {
              setState(() => _dateRange = r);
              _reload();
            },
    );
    final refresh = IconButton(
      icon: const Icon(Icons.refresh, size: 20),
      color: ZohoPalette.textMuted,
      tooltip: 'Reload from Xero',
      onPressed: _isLoading ? null : _refresh,
      visualDensity: VisualDensity.compact,
    );
    final settings = IconButton(
      icon: const Icon(Icons.settings_outlined, size: 20),
      color: ZohoPalette.textMuted,
      tooltip: 'Share message templates',
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => const InvoiceMessageSettingsDialog(),
      ),
    );

    return ColoredBox(
      // White, not the page grey: the view sits inside a bordered panel, and
      // grey below the last row read as the panel ending early.
      color: ZohoPalette.surface,
      child: Column(
        children: [
          LayoutBuilder(builder: (context, constraints) {
            if (constraints.maxWidth >= 700) {
              return ZohoToolbar(
                // Aligned so the filter keeps its natural width — the toolbar
                // gives its leading slot all the spare room, and a dropdown
                // stretched across it read as a second search box.
                leading: Align(
                  alignment: Alignment.centerLeft,
                  child: statusFilter,
                ),
                actions: [
                  search,
                  const SizedBox(width: 8),
                  dateFilter,
                  const SizedBox(width: 8),
                  refresh,
                  settings,
                ],
              );
            }
            // Too narrow for one row: the actions took 80% and left the
            // status filter ~70px to overflow from. Filters on top, search
            // full width beneath.
            return Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
              decoration: const BoxDecoration(
                color: ZohoPalette.surface,
                border: Border(bottom: BorderSide(color: ZohoPalette.border)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            statusFilter,
                            const SizedBox(width: 8),
                            dateFilter,
                          ]),
                        ),
                      ),
                      refresh,
                      settings,
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    // Tight width overrides the field's own fixed 260.
                    child: SizedBox(width: double.infinity, child: search),
                  ),
                ],
              ),
            );
          }),
          // A failed refresh keeps the rows it already has and explains itself
          // above them; only an empty list escalates to the full-screen error
          // inside ZohoAsyncBody.
          if (_error != null && _invoices.isNotEmpty)
            _ErrorBanner(message: _error!, onRetry: _reload),
          if (amountPanel != null && _invoices.isNotEmpty) amountPanel,
          if (_isLoading && (_invoices.isNotEmpty || amountPanel != null))
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ZohoAsyncBody(
              isLoading: _isLoading,
              error: _invoices.isEmpty ? _error : null,
              // An amount search with no match explains itself in full
              // rather than a bare "No invoices match".
              isEmpty: _invoices.isEmpty && amountPanel == null,
              emptyIcon: Icons.receipt_long_outlined,
              emptyMessage: _emptyMessage,
              onRetry: _reload,
              child: _invoices.isEmpty && amountPanel != null
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 640),
                          child: amountPanel,
                        ),
                      ),
                    )
                  : ZohoTable(
                columns: showMatches
                    ? const [..._columns, _matchColumn]
                    : _columns,
                rowCount: _invoices.length,
                sortColumnIndex: _sortColumn,
                sortAscending: _sortAscending,
                onSort: _onSort,
                onRowTap: (index) => _openInvoice(_invoices[index].invoiceId),
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
                      tabular: true,
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
                      tabular: true,
                    ),
                    ZohoCellText(currency.format(inv.total),
                        strikeThrough: struck, tabular: true),
                    // Nothing owing reads as a dash, so the money that is
                    // owed is what the eye lands on. Red only here: the row
                    // tint, accent and status already say "overdue" three
                    // times, so a red due date as well was noise.
                    inv.amountDue <= 0
                        ? const ZohoCellText('', muted: true)
                        : ZohoCellText(
                            currency.format(inv.amountDue),
                            strikeThrough: struck,
                            tabular: true,
                            weight: FontWeight.w600,
                            color: inv.isOverdue ? _overdueRed : null,
                          ),
                    if (showMatches)
                      switch (_amountMatches[inv.invoiceId]) {
                        // Found by number/reference, not by amount.
                        null => const ZohoCellText('—', muted: true),
                        final m => Tooltip(
                            message: m.detail.isEmpty ? m.label : m.detail,
                            waitDuration: const Duration(milliseconds: 300),
                            child: ZohoCellText(m.label,
                                weight: FontWeight.w600),
                          ),
                      },
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

/// What an amount search checked and found, check by check — so "no match"
/// is never mistaken for "checked everything".
class _AmountSummary {
  final int cents;
  final String statusLabel;
  final String dateLabel;
  final bool allStatuses;
  final bool allDates;

  /// Whole-invoice figures: total, amount due, amount paid.
  final int totalsMatches;
  final String? totalsError;

  /// Lines and combinations of lines, from the cached scan.
  final String scanStatusWord;
  final int scannedInvoices;
  final int scannedLines;
  final bool scanTruncated;
  final String? scanError;
  final int lineMatches;

  /// Invoice number / reference containing the typed text.
  final int textMatches;
  final bool textHasMore;

  /// Closest figures, filled only when nothing matched exactly.
  final List<XeroAmountNearMiss> nearMisses;

  const _AmountSummary({
    required this.cents,
    required this.statusLabel,
    required this.dateLabel,
    required this.allStatuses,
    required this.allDates,
    required this.totalsMatches,
    required this.totalsError,
    required this.scanStatusWord,
    required this.scannedInvoices,
    required this.scannedLines,
    required this.scanTruncated,
    required this.scanError,
    required this.lineMatches,
    required this.nearMisses,
    this.textMatches = 0,
    this.textHasMore = false,
  });

  int get amountMatches => totalsMatches + lineMatches;

  _AmountSummary withText(int matches, bool hasMore) => _AmountSummary(
        cents: cents,
        statusLabel: statusLabel,
        dateLabel: dateLabel,
        allStatuses: allStatuses,
        allDates: allDates,
        totalsMatches: totalsMatches,
        totalsError: totalsError,
        scanStatusWord: scanStatusWord,
        scannedInvoices: scannedInvoices,
        scannedLines: scannedLines,
        scanTruncated: scanTruncated,
        scanError: scanError,
        lineMatches: lineMatches,
        nearMisses: nearMisses,
        textMatches: matches,
        textHasMore: hasMore,
      );
}

/// The amount search's report: a headline, one row per check with its count,
/// the closest figures when nothing matched, and ways to widen the search.
///
/// Collapsed to the headline above a results table; shown in full in place
/// of the table when nothing was found.
class _AmountSearchPanel extends StatelessWidget {
  final _AmountSummary summary;
  final bool expanded;

  /// Null when the panel cannot collapse — the empty state.
  final VoidCallback? onToggle;
  final VoidCallback? onAllStatuses;
  final VoidCallback? onAllDates;
  final void Function(String invoiceId) onOpenInvoice;

  const _AmountSearchPanel({
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.onAllStatuses,
    required this.onAllDates,
    required this.onOpenInvoice,
  });

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 'es'}';

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final amount = XeroAmountSearch.format(s.cents);
    final found = s.amountMatches;
    final isEmptyState = onToggle == null;

    final headline = found > 0
        ? '${found == 1 ? '1 invoice matches' : '$found invoices match'} $amount'
        : 'No invoice matches $amount exactly';
    final scope = [
      s.allStatuses ? 'All statuses' : s.statusLabel,
      s.dateLabel,
      if (s.textMatches > 0)
        '${s.textMatches}${s.textHasMore ? '+' : ''} more by invoice number',
    ].join(' · ');

    final header = Row(
      children: [
        Icon(
          found > 0 ? Icons.payments_outlined : Icons.search_off,
          size: 20,
          color: found > 0 ? Colors.green.shade700 : ZohoPalette.textMuted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(headline,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(scope,
                  style: const TextStyle(
                      fontSize: 12, color: ZohoPalette.textMuted)),
            ],
          ),
        ),
        if (onToggle != null)
          TextButton.icon(
            onPressed: onToggle,
            icon: Icon(expanded ? Icons.expand_less : Icons.expand_more,
                size: 18),
            label: Text(expanded ? 'Hide details' : 'Details'),
          ),
      ],
    );

    final scanScope = s.scannedInvoices == 0
        ? 'No ${s.scanStatusWord} invoices to check'
        : 'Checked ${s.scanTruncated ? 'the newest ' : ''}'
            '${s.scannedInvoices} ${s.scanStatusWord} '
            'invoice${s.scannedInvoices == 1 ? '' : 's'} '
            '(${s.scannedLines} line${s.scannedLines == 1 ? '' : 's'})';

    final checks = [
      _CheckRow(
        title: 'Invoice total, amount due or amount paid',
        detail: s.allStatuses
            ? 'Searched in Xero across every status'
            : 'Searched in Xero across ${s.statusLabel.toLowerCase()} invoices',
        error: s.totalsError,
        result: _count(s.totalsMatches, 'match'),
        hit: s.totalsMatches > 0,
      ),
      _CheckRow(
        title: 'One line, or several lines added together',
        detail: '$scanScope — with and without VAT'
            '${s.allStatuses ? '. Pick a status to check others.' : ''}',
        error: s.scanError,
        result: _count(s.lineMatches, 'match'),
        hit: s.lineMatches > 0,
      ),
      _CheckRow(
        title: 'Invoice number or reference',
        detail: 'Contains the text you typed',
        result: '${_count(s.textMatches, 'match')}${s.textHasMore ? '+' : ''}',
        hit: s.textMatches > 0,
      ),
    ];

    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final nearMisses = [
      if (s.nearMisses.isNotEmpty) ...[
        const SizedBox(height: 14),
        const Text('Closest amounts',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        for (final m in s.nearMisses)
          InkWell(
            onTap: () => onOpenInvoice(m.invoice.invoiceId),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 90,
                    child: Text(m.invoice.invoiceNumber,
                        style: const TextStyle(
                            fontSize: 12, color: ZohoPalette.link)),
                  ),
                  Expanded(
                    child: Text(
                      '${m.invoice.contactName} · ${m.label}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    currency.format(m.cents / 100),
                    style: const TextStyle(
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                  SizedBox(
                    width: 100,
                    child: Text(
                      '${m.diffCents > 0 ? '+' : '−'}'
                      '${currency.format(m.diffCents.abs() / 100)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 12,
                          color: ZohoPalette.textMuted,
                          fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ];

    final widen = [
      if (found == 0 && (onAllStatuses != null || onAllDates != null)) ...[
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (onAllStatuses != null)
              OutlinedButton.icon(
                onPressed: onAllStatuses,
                icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
                label: const Text('Search all statuses'),
              ),
            if (onAllDates != null)
              OutlinedButton.icon(
                onPressed: onAllDates,
                icon: const Icon(Icons.event_busy_outlined, size: 16),
                label: const Text('Search all dates'),
              ),
          ],
        ),
      ],
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
      decoration: BoxDecoration(
        color: found > 0 ? Colors.green.shade50 : ZohoPalette.surface,
        border: isEmptyState
            ? Border.all(color: ZohoPalette.border)
            : const Border(bottom: BorderSide(color: ZohoPalette.border)),
        borderRadius: isEmptyState ? BorderRadius.circular(8) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (expanded) ...[
            const SizedBox(height: 10),
            ...checks,
            ...nearMisses,
            ...widen,
          ],
        ],
      ),
    );
  }
}

/// One check of an amount search: what was searched, where, and how many
/// it found — or why it could not run.
class _CheckRow extends StatelessWidget {
  final String title;
  final String detail;
  final String? error;
  final String result;
  final bool hit;

  const _CheckRow({
    required this.title,
    required this.detail,
    required this.result,
    required this.hit,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            failed
                ? Icons.error_outline
                : hit
                    ? Icons.check_circle
                    : Icons.remove_circle_outline,
            size: 16,
            color: failed
                ? Colors.red.shade400
                : hit
                    ? Colors.green.shade600
                    : ZohoPalette.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                Text(
                  failed ? 'Could not check — $error' : detail,
                  style: TextStyle(
                    fontSize: 12,
                    color: failed ? Colors.red.shade700 : ZohoPalette.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            failed ? '—' : result,
            style: TextStyle(
              fontSize: 12,
              fontWeight: hit ? FontWeight.w600 : FontWeight.normal,
              color: hit ? Colors.green.shade800 : ZohoPalette.textMuted,
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
