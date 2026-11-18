import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/zoho_invoice.dart';
import '../../providers/zoho_invoices_provider.dart';
import 'invoice_message_settings_dialog.dart';
import 'zoho_item_autofill_dialog.dart';
import 'zoho_invoice_detail_screen.dart';
import 'zoho_status_chip.dart';
import 'zoho_table.dart';

/// Invoice list, laid out like the Zoho Books web invoice table.
///
/// A body, not a screen: it lives in a tab of [ZohoBooksScreen] and so carries
/// no Scaffold or AppBar of its own.
class ZohoInvoicesView extends riverpod.ConsumerStatefulWidget {
  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const ZohoInvoicesView({super.key, required this.orgId});

  @override
  riverpod.ConsumerState<ZohoInvoicesView> createState() =>
      _ZohoInvoicesViewState();
}

class _ZohoInvoicesViewState extends riverpod.ConsumerState<ZohoInvoicesView>
    with AutomaticKeepAliveClientMixin {
  // Keeps the loaded pages, scroll position and filters across tab switches —
  // rebuilding would refetch, and every fetch is a rate-limited Zoho call.
  @override
  bool get wantKeepAlive => true;

  final _searchController = TextEditingController();

  /// Search now refetches from Zoho instead of filtering in memory, so it is
  /// debounced rather than firing a request per keystroke.
  Timer? _searchDebounce;

  /// Statuses offered as filters. Zoho accepts these as `?status=` values.
  static const _filterable = <ZohoInvoiceStatus?>[
    null, // All
    ZohoInvoiceStatus.draft,
    ZohoInvoiceStatus.sent,
    ZohoInvoiceStatus.overdue,
    ZohoInvoiceStatus.paid,
    ZohoInvoiceStatus.partiallyPaid,
    ZohoInvoiceStatus.isVoid,
  ];

  static const _columns = <ZohoColumn>[
    ZohoColumn(label: 'Date', width: 110),
    ZohoColumn(label: 'Invoice#', width: 140),
    ZohoColumn(label: 'Customer Name', width: 200, flexible: true),
    // Zoho rejects sort_column=status, and sorting only the loaded pages
    // locally would be misleading — so this column is not sortable.
    ZohoColumn(label: 'Status', width: 130, sortable: false),
    ZohoColumn(label: 'Due Date', width: 110),
    ZohoColumn(label: 'Amount', width: 120, alignment: Alignment.centerRight),
    ZohoColumn(label: 'Balance', width: 120, alignment: Alignment.centerRight),
  ];

  @override
  void initState() {
    super.initState();
    // Sorting maps a header index onto ZohoInvoiceSort.values, so the two
    // must stay the same length and order.
    assert(_columns.length == ZohoInvoiceSort.values.length,
        'Column count must match ZohoInvoiceSort — sorting maps by index.');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(zohoInvoicesRiverpod(widget.orgId)).initialize();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      ref.read(zohoInvoicesRiverpod(widget.orgId)).setSearchText(value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = ref.watch(zohoInvoicesRiverpod(widget.orgId));
    final invoices = provider.filteredInvoices;
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final dateFormat = DateFormat('d MMM y');

    return ColoredBox(
      // White: the view sits inside a bordered ZohoPanel.
      color: ZohoPalette.surface,
      child: Column(
        children: [
          ZohoToolbar(
            leading: ZohoStatusFilterDropdown(
              value: provider.statusFilter,
              options: _filterable,
              allLabel: 'All Invoices',
              // Changing the filter refetches — Zoho filters server-side
              // rather than us paging everything locally.
              onChanged: provider.isLoading ? null : provider.setStatusFilter,
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
                  provider.setSearchText('');
                },
              ),
              const SizedBox(width: 8),
              ZohoFilterDropdown<ZohoDateRange>(
                value: provider.dateRange,
                icon: Icons.event,
                options: {
                  for (final r in ZohoDateRange.values) r: r.label,
                },
                onChanged: provider.setDateRange,
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                color: ZohoPalette.textMuted,
                tooltip: 'Reload from Zoho',
                onPressed: provider.isLoading ? null : provider.refresh,
              ),
              // Two settings surfaces now, so a menu rather than a second
              // unlabelled gear icon nobody could tell apart.
              PopupMenuButton<String>(
                icon: const Icon(Icons.settings_outlined,
                    size: 20, color: ZohoPalette.textMuted),
                tooltip: 'Settings',
                onSelected: (choice) => showDialog<void>(
                  context: context,
                  builder: (_) => choice == 'messages'
                      ? const InvoiceMessageSettingsDialog()
                      : ZohoItemAutofillDialog(orgId: widget.orgId),
                ),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'messages',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.chat_outlined, size: 18),
                      title: Text('Share message templates',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'autofill',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.playlist_add, size: 18),
                      title: Text('Invoice line autofill',
                          style: TextStyle(fontSize: 13)),
                      subtitle: Text('What each item puts on the line',
                          style: TextStyle(fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (provider.isLoading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ZohoAsyncBody(
              isLoading: provider.isLoading,
              error: provider.error,
              isEmpty: invoices.isEmpty,
              emptyMessage: provider.searchText.isNotEmpty
                  ? 'No invoices match "${provider.searchText}"'
                      '${provider.statusFilter == null ? '' : ' (${provider.statusFilter!.label.toLowerCase()} only)'}'
                      '${provider.dateRange == ZohoDateRange.all ? '' : ' in ${provider.dateRange.label.toLowerCase()}'}.'
                  : provider.statusFilter == null
                      ? 'No invoices in Zoho Books yet.'
                      : 'No ${provider.statusFilter!.label.toLowerCase()} invoices.',
              onRetry: provider.refresh,
              child: ZohoTable(
                columns: _columns,
                rowCount: invoices.length,
                // _columns is declared in ZohoInvoiceSort order, so the
                // header index maps straight onto the sort field.
                sortColumnIndex: provider.sortBy.index,
                sortAscending: provider.sortAscending,
                onSort: (i) => provider.sortByField(ZohoInvoiceSort.values[i]),
                // Lazy paging — 25 at a time, appended on scroll or via the
                // footer button (the only route when the rows all fit).
                onEndReached: provider.loadMore,
                isLoadingMore: provider.isLoadingMore,
                hasMore: provider.hasMore,
                // Status colour on each row: green paid, red overdue, blue
                // sent, orange part-paid, grey draft / void.
                rowAccent: (index) => invoices[index].status.color,
                onRowTap: (index) => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ZohoInvoiceDetailScreen(
                        orgId: widget.orgId,
                        invoiceId: invoices[index].invoiceId),
                  ),
                ),
                rowBuilder: (context, index) {
                  final inv = invoices[index];
                  final struck = inv.status.isStruckThrough;
                  return [
                    ZohoCellText(
                      inv.date == null ? '' : dateFormat.format(inv.date!),
                      muted: true,
                    ),
                    ZohoLinkText(
                      inv.invoiceNumber.isNotEmpty
                          ? inv.invoiceNumber
                          : '(no number)',
                      strikeThrough: struck,
                    ),
                    ZohoCellText(inv.customerName, strikeThrough: struck),
                    ZohoStatusChip(status: inv.status, dense: true),
                    ZohoCellText(
                      inv.dueDate == null
                          ? ''
                          : dateFormat.format(inv.dueDate!),
                      muted: true,
                    ),
                    ZohoCellText(
                      currency.format(inv.total),
                      strikeThrough: struck,
                      weight: FontWeight.w600,
                    ),
                    ZohoCellText(
                      currency.format(inv.balance),
                      muted: inv.balance == 0 || struck,
                      strikeThrough: struck,
                    ),
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
