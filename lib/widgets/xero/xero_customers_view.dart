import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

import '../../models/xero_contact.dart';
import '../../services/xero_accounting_service.dart';
import '../zoho/zoho_status_chip.dart';
import '../zoho/zoho_table.dart';
import 'xero_contact_form_dialog.dart';
import 'xero_contact_detail_screen.dart';

/// Community Life Media's customers, read from Xero.
///
/// A body-only view with no Scaffold of its own — hosted as a tab inside
/// [XeroAccountingScreen].
///
/// Unlike the Zoho customers screen — which loads all 826 contacts so the
/// picker can name-match locally — this pages server-side and searches through
/// Xero's `searchTerm`. On a 1,000-call daily budget, pulling the whole book on
/// every visit is not affordable.
class XeroCustomersView extends riverpod.ConsumerStatefulWidget {
  const XeroCustomersView({super.key});

  @override
  riverpod.ConsumerState<XeroCustomersView> createState() =>
      _XeroCustomersViewState();
}

class _XeroCustomersViewState extends riverpod.ConsumerState<XeroCustomersView>
    with AutomaticKeepAliveClientMixin {
  // Kept alive so switching tabs does not refetch.
  @override
  bool get wantKeepAlive => true;

  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  static const _columns = <ZohoColumn>[
    ZohoColumn(label: 'Name', width: 220, flexible: true),
    ZohoColumn(label: 'Contact', width: 180),
    ZohoColumn(label: 'Email', width: 220),
    ZohoColumn(label: 'Phone', width: 150, sortable: false),
    ZohoColumn(label: 'Status', width: 100, sortable: false),
    ZohoColumn(
        label: 'Outstanding', width: 130, alignment: Alignment.centerRight),
  ];

  static const _sortFields = <String?>[
    'Name',
    'FirstName',
    'EmailAddress',
    null,
    null,
    null,
  ];

  final List<XeroContact> _contacts = [];
  String _searchTerm = '';
  int _sortColumn = 0;
  bool _sortAscending = true;

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

  Future<void> _reload() async {
    setState(() {
      _isLoading = true;
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

  Future<void> _fetch({required bool replace}) async {
    final service = ref.read(xeroAccountingServiceRiverpod);
    try {
      final page = await service.listContacts(
        searchTerm: _searchTerm.isEmpty ? null : _searchTerm,
        order: _order,
        page: _page,
        pageSize: 100,
      );
      if (!mounted) return;
      setState(() {
        if (replace) _contacts.clear();
        _contacts.addAll(page.items);
        _hasMore = page.hasMore;
        _isLoading = false;
        _isLoadingMore = false;
      });
    } on XeroException catch (e) {
      if (!mounted) return;
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
        _sortAscending = true;
      }
    });
    _reload();
  }

  /// Create a customer straight in Xero.
  ///
  /// Seeded with whatever is in the search box: reaching for "New customer"
  /// almost always follows a search that found nothing, and retyping the name
  /// is the obvious thing to resent.
  Future<void> _createContact() async {
    final saved = await showXeroContactFormDialog(
      context,
      seedName: _searchController.text.trim(),
    );
    if (saved == null || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Created ${saved.displayName} in Xero'),
        backgroundColor: Colors.green,
      ),
    );
    // Re-read rather than splicing the new contact into the list: the page is
    // server-side sorted and filtered, so guessing where it belongs would put
    // it in the wrong place or hide it behind the current search.
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final currency = NumberFormat.currency(symbol: 'R ', decimalDigits: 2);

    return ColoredBox(
      color: ZohoPalette.pageBackground,
      child: Column(
        children: [
          ZohoToolbar(
            leading: const SizedBox.shrink(),
            actions: [
              ZohoSearchField(
                controller: _searchController,
                hintText: 'Search customers',
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
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                color: ZohoPalette.textMuted,
                tooltip: 'Reload from Xero',
                onPressed: _isLoading ? null : _reload,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              // The shared primary button, so this sits identically to Zoho's.
              ZohoNewButton(
                label: 'New',
                onPressed: _isLoading ? null : _createContact,
              ),
            ],
          ),
          // A failed refresh keeps the rows it already has; only an empty list
          // escalates to the full-screen error inside ZohoAsyncBody.
          if (_error != null && _contacts.isNotEmpty)
            _ErrorBanner(message: _error!, onRetry: _reload),
          if (_isLoading && _contacts.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ZohoAsyncBody(
              isLoading: _isLoading,
              error: _contacts.isEmpty ? _error : null,
              isEmpty: _contacts.isEmpty,
              emptyIcon: Icons.people_outline,
              emptyMessage: _searchTerm.isEmpty
                  ? 'No customers in Xero yet.'
                  : 'No customers match "$_searchTerm".',
              // An empty search result is the usual route to creating someone.
              emptyActionLabel: 'New customer',
              onEmptyAction: _createContact,
              onRetry: _reload,
              child: ZohoTable(
                columns: _columns,
                rowCount: _contacts.length,
                sortColumnIndex: _sortColumn,
                sortAscending: _sortAscending,
                onSort: _onSort,
                onRowTap: (index) => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => XeroContactDetailScreen(
                      contactId: _contacts[index].contactId,
                      initialName: _contacts[index].displayName,
                    ),
                  ),
                ),
                onEndReached: _loadMore,
                isLoadingMore: _isLoadingMore,
                hasMore: _hasMore,
                rowBuilder: (context, index) {
                  final c = _contacts[index];
                  final person = [c.firstName, c.lastName]
                      .where((p) => p.isNotEmpty)
                      .join(' ');
                  return [
                    ZohoLinkText(c.displayName),
                    ZohoCellText(person),
                    ZohoCellText(c.emailAddress),
                    ZohoCellText(c.bestPhone),
                    ZohoCellText(c.isActive ? 'Active' : 'Archived'),
                    ZohoCellText(c.outstandingReceivable == 0
                        ? ''
                        : currency.format(c.outstandingReceivable)),
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
          Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
