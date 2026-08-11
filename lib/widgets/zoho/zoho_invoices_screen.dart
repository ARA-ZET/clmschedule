import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/zoho_invoice.dart';
import '../../providers/zoho_invoices_provider.dart';
import 'zoho_invoice_detail_screen.dart';
import 'zoho_status_chip.dart';

/// Invoice list with a server-side status filter and colour-coded chips.
class ZohoInvoicesScreen extends riverpod.ConsumerStatefulWidget {
  const ZohoInvoicesScreen({super.key});

  @override
  riverpod.ConsumerState<ZohoInvoicesScreen> createState() =>
      _ZohoInvoicesScreenState();
}

class _ZohoInvoicesScreenState
    extends riverpod.ConsumerState<ZohoInvoicesScreen> {
  final _searchController = TextEditingController();

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(zohoInvoicesRiverpod).initialize();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(zohoInvoicesRiverpod);
    final invoices = provider.filteredInvoices;
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);
    final dateFormat = DateFormat('d MMM y');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Invoices'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload from Zoho',
            onPressed: provider.isLoading ? null : provider.refresh,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: provider.setSearchText,
                  decoration: InputDecoration(
                    hintText: 'Search invoice no., customer or reference',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: const OutlineInputBorder(),
                    suffixIcon: provider.searchText.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              provider.setSearchText('');
                            },
                          ),
                  ),
                ),
              ),
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _filterable.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final status = _filterable[index];
                    final selected = provider.statusFilter == status;
                    return ChoiceChip(
                      label: Text(status?.label ?? 'All'),
                      selected: selected,
                      // Changing the filter refetches — Zoho filters
                      // server-side rather than us paging everything locally.
                      onSelected: provider.isLoading
                          ? null
                          : (_) => provider.setStatusFilter(status),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          if (provider.isLoading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ZohoAsyncBody(
              isLoading: provider.isLoading,
              error: provider.error,
              isEmpty: invoices.isEmpty,
              emptyMessage: provider.statusFilter == null
                  ? 'No invoices in Zoho Books yet.'
                  : 'No ${provider.statusFilter!.label.toLowerCase()} invoices.',
              onRetry: provider.refresh,
              child: ListView.separated(
                itemCount: invoices.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final inv = invoices[index];
                  final isVoid = inv.status.isStruckThrough;
                  return ListTile(
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            inv.invoiceNumber.isNotEmpty
                                ? inv.invoiceNumber
                                : '(no number)',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              decoration:
                                  isVoid ? TextDecoration.lineThrough : null,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ZohoStatusChip(status: inv.status, dense: true),
                      ],
                    ),
                    subtitle: Text(
                      [
                        if (inv.customerName.isNotEmpty) inv.customerName,
                        if (inv.date != null) dateFormat.format(inv.date!),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          currency.format(inv.total),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            decoration:
                                isVoid ? TextDecoration.lineThrough : null,
                          ),
                        ),
                        if (inv.balance > 0 && !isVoid)
                          Text(
                            'Due ${currency.format(inv.balance)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.red.shade700,
                            ),
                          ),
                      ],
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ZohoInvoiceDetailScreen(invoiceId: inv.invoiceId),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
