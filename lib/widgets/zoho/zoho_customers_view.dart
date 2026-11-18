import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/zoho_customer.dart';
import '../../providers/zoho_customers_provider.dart';
import 'customer_form_dialog.dart';
import 'zoho_status_chip.dart';
import 'zoho_table.dart';

/// Customer list, laid out like the Zoho Books web Contacts table.
///
/// A body, not a screen: it lives in a tab of [ZohoBooksScreen] and so carries
/// no Scaffold or AppBar of its own.
class ZohoCustomersView extends riverpod.ConsumerStatefulWidget {
  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const ZohoCustomersView({super.key, required this.orgId});

  @override
  riverpod.ConsumerState<ZohoCustomersView> createState() =>
      _ZohoCustomersViewState();
}

class _ZohoCustomersViewState extends riverpod.ConsumerState<ZohoCustomersView>
    with AutomaticKeepAliveClientMixin {
  // Kept alive so switching tabs does not refetch — this list is the whole
  // contact book in one call.
  @override
  bool get wantKeepAlive => true;

  final _searchController = TextEditingController();

  static const _columns = <ZohoColumn>[
    ZohoColumn(label: 'Name', width: 200, flexible: true),
    ZohoColumn(label: 'Company Name', width: 180),
    ZohoColumn(label: 'Email', width: 210),
    // Your Zoho data is overwhelmingly mobile rather than work phone, so this
    // column shows whichever is set instead of leaving a near-empty column.
    ZohoColumn(label: 'Phone', width: 150),
    ZohoColumn(
        label: 'Receivables', width: 130, alignment: Alignment.centerRight),
  ];

  @override
  void initState() {
    super.initState();
    // Sorting maps a header index onto ZohoCustomerSort.values, so the two
    // must stay the same length and order.
    assert(_columns.length == ZohoCustomerSort.values.length,
        'Column count must match ZohoCustomerSort — sorting maps by index.');
    // Loads on first open rather than in the provider constructor — each load
    // is a rate-limited Zoho call.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(zohoCustomersRiverpod(widget.orgId)).initialize();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openForm({ZohoCustomer? existing}) async {
    var toEdit = existing;

    // The list response omits contact_persons, so an edit must start from a
    // detail fetch — without the primary contact_person_id, saving would add
    // a second contact person instead of amending the existing one.
    if (existing != null && existing.primaryContactPersonId.isEmpty) {
      try {
        toEdit = await ref
            .read(zohoCustomersRiverpod(widget.orgId))
            .loadFullCustomer(existing.contactId);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showToast(
          SnackBar(
            content: Text('Could not load customer: $e'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
    }

    if (!mounted) return;
    final saved = await showDialog<ZohoCustomer>(
      context: context,
      builder: (_) => CustomerFormDialog(orgId: widget.orgId, existing: toEdit),
    );
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context).showToast(
        SnackBar(
          content:
              Text(existing == null ? 'Customer created' : 'Customer updated'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = ref.watch(zohoCustomersRiverpod(widget.orgId));
    final customers = provider.filteredCustomers;
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);

    return ColoredBox(
      // White: the view sits inside a bordered ZohoPanel.
      color: ZohoPalette.surface,
      child: Column(
        children: [
          ZohoToolbar(
            leading: const Text(
              'All Customers',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: ZohoPalette.textPrimary,
              ),
            ),
            actions: [
              ZohoSearchField(
                controller: _searchController,
                hintText: 'Search customers',
                onChanged: provider.setSearchText,
                showClear: provider.searchText.isNotEmpty,
                onClear: () {
                  _searchController.clear();
                  provider.setSearchText('');
                },
              ),
              const SizedBox(width: 8),
              ZohoFilterDropdown<ZohoCustomerFilter>(
                value: provider.filter,
                options: {
                  for (final f in ZohoCustomerFilter.values) f: f.label,
                },
                onChanged: provider.setFilter,
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                color: ZohoPalette.textMuted,
                tooltip: 'Reload from Zoho',
                onPressed: provider.isLoading ? null : provider.refresh,
              ),
              const SizedBox(width: 8),
              ZohoNewButton(label: 'New', onPressed: () => _openForm()),
            ],
          ),
          if (provider.isLoading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ZohoAsyncBody(
              isLoading: provider.isLoading,
              error: provider.error,
              isEmpty: customers.isEmpty,
              emptyMessage: provider.searchText.isEmpty
                  ? 'No customers in Zoho Books yet.'
                  : 'No customers match "${provider.searchText}".',
              onRetry: provider.refresh,
              child: ZohoTable(
                columns: _columns,
                rowCount: customers.length,
                // _columns is declared in ZohoCustomerSort order, so the
                // header index maps straight onto the sort field.
                sortColumnIndex: provider.sortBy.index,
                sortAscending: provider.sortAscending,
                onSort: (i) => provider.sortByField(ZohoCustomerSort.values[i]),
                onRowTap: (index) => _openForm(existing: customers[index]),
                rowBuilder: (context, index) {
                  final c = customers[index];
                  return [
                    ZohoLinkText(c.displayName),
                    ZohoCellText(c.companyName),
                    ZohoCellText(c.email),
                    ZohoCellText(c.bestPhone),
                    ZohoCellText(
                      currency.format(c.outstandingReceivable),
                      muted: c.outstandingReceivable == 0,
                      weight:
                          c.outstandingReceivable > 0 ? FontWeight.w600 : null,
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
