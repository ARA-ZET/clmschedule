import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/xero_contact.dart';
import '../../services/xero_accounting_service.dart';
import '../zoho/customer_result_tile.dart';
import '../zoho/zoho_table.dart';
import 'xero_contact_form_dialog.dart';

/// Pick an existing Xero contact, or fill in a new one.
///
/// Searches server-side through Xero's `searchTerm` rather than loading the
/// whole contact book the way the Zoho picker does — on 1,000 calls/day,
/// pulling every contact to name-match locally is not affordable.
///
/// The distinction that matters is [XeroContact.existsInXero]: a contact with
/// no id is a *seed for a new one*, not an edit of an existing one. The caller
/// keys create-vs-reuse on that, never on "is the value non-null".
class XeroContactPicker extends riverpod.ConsumerStatefulWidget {
  final XeroContact? value;
  final ValueChanged<XeroContact?> onChanged;

  /// Pre-filled into the name field when creating a new contact.
  final String seedName;

  const XeroContactPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.seedName = '',
  });

  @override
  riverpod.ConsumerState<XeroContactPicker> createState() =>
      _XeroContactPickerState();
}

class _XeroContactPickerState
    extends riverpod.ConsumerState<XeroContactPicker> {
  final _searchController = TextEditingController();

  Timer? _debounce;
  List<XeroContact> _results = const [];
  bool _isSearching = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Create the contact in Xero now, rather than leaving it to the saga.
  ///
  /// The customer exists in the books the moment this returns, so the invoice
  /// step has nothing to create and a failure there cannot leave a
  /// half-finished customer behind. Matches how the Zoho picker has always
  /// behaved.
  Future<void> _createNew() async {
    final seed = _searchController.text.trim().isNotEmpty
        ? _searchController.text.trim()
        : widget.seedName;

    final created = await showXeroContactFormDialog(context, seedName: seed);
    if (created != null) widget.onChanged(created);
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(value));
  }

  Future<void> _search(String term) async {
    final query = term.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _error = null;
    });

    try {
      final page = await ref
          .read(xeroAccountingServiceRiverpod)
          .listContacts(searchTerm: query, pageSize: 20);
      if (!mounted) return;
      setState(() {
        _results = page.items;
        _isSearching = false;
      });
    } on XeroException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _isSearching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.value;

    // An existing contact is chosen — show it, with a way back.
    if (selected != null && selected.existsInXero) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.person, color: Color(0xFF2B7DE9)),
          title: Text(selected.displayName),
          subtitle: Text([
            if (selected.emailAddress.isNotEmpty) selected.emailAddress,
            if (selected.bestPhone.isNotEmpty) selected.bestPhone,
          ].join(' · ')),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Choose a different customer',
            onPressed: () {
              setState(() {
                _results = const [];
                _searchController.clear();
              });
              widget.onChanged(null);
            },
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search and create share a row: they are the two ways to answer the
        // same question, and stacking them read as two unrelated controls.
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  labelText: 'Search Xero customers',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _isSearching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _createNew,
              icon: const Icon(Icons.person_add, size: 16),
              label: const Text('New'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF2B7DE9),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                textStyle: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!,
                style: const TextStyle(fontSize: 11, color: Colors.red)),
          ),
        if (_results.isNotEmpty)
          ConstrainedBox(
            // Roomy enough to see several candidates at once: choosing between
            // two similarly named clients is the moment this list exists for.
            constraints: const BoxConstraints(maxHeight: 320),
            child: Card(
              margin: const EdgeInsets.only(top: 6),
              clipBehavior: Clip.antiAlias,
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _results.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: ZohoPalette.border),
                itemBuilder: (context, index) {
                  final c = _results[index];
                  return CustomerResultTile(
                    name: c.displayName,
                    subtitle: [c.firstName, c.lastName]
                        .where((p) => p.isNotEmpty)
                        .join(' '),
                    email: c.emailAddress,
                    phone: c.bestPhone,
                    onTap: () => widget.onChanged(c),
                  );
                },
              ),
            ),
          ),
        if (_searchController.text.trim().isNotEmpty &&
            _results.isEmpty &&
            !_isSearching &&
            _error == null)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('No matching customers',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
      ],
    );
  }
}
