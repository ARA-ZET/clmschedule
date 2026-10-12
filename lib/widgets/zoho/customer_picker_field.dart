import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/zoho_customer.dart';
import '../../providers/zoho_customers_provider.dart';
import 'customer_form_dialog.dart';
import 'customer_result_tile.dart';
import 'zoho_table.dart';

/// Type-ahead picker for a Zoho customer, with inline "new customer".
///
/// A plain [DropdownButtonFormField] is unusable here — this org has 800+
/// customers — so this is an [Autocomplete] that filters as you type and caps
/// the suggestion list.
class CustomerPickerField extends riverpod.ConsumerStatefulWidget {
  final ZohoCustomer? selected;
  final ValueChanged<ZohoCustomer?> onSelected;

  /// Free-text client name from the job, used to pre-fill the **search box**.
  final String initialQuery;

  /// Contact name to pre-fill when creating a **new** customer. Kept separate
  /// from [initialQuery] because the two differ: searching wants the bare
  /// client name, while a new contact is named "client, area". Falls back to
  /// [initialQuery] when empty.
  final String newCustomerSeedName;

  final bool enabled;

  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const CustomerPickerField({
    super.key,
    required this.orgId,
    required this.selected,
    required this.onSelected,
    this.initialQuery = '',
    this.newCustomerSeedName = '',
    this.enabled = true,
  });

  @override
  riverpod.ConsumerState<CustomerPickerField> createState() =>
      _CustomerPickerFieldState();
}

class _CustomerPickerFieldState
    extends riverpod.ConsumerState<CustomerPickerField> {
  /// Cap on suggestions shown at once — rendering hundreds of options in an
  /// overlay is slow and unhelpful.
  static const _maxSuggestions = 40;

  @override
  void initState() {
    super.initState();
    // Customers are loaded lazily, so make sure they exist before the user
    // starts typing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(zohoCustomersRiverpod(widget.orgId)).initialize();
    });
  }

  Future<void> _createNew(String seedName) async {
    final created = await showDialog<ZohoCustomer>(
      context: context,
      builder: (_) => CustomerFormDialog(
        orgId: widget.orgId,
        existing: seedName.trim().isEmpty
            ? null
            // Seeds the form with the job's client name; contactId stays empty
            // so CustomerFormDialog still treats this as a create.
            : ZohoCustomer(contactId: '', contactName: seedName.trim()),
      ),
    );
    if (created != null) widget.onSelected(created);
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(zohoCustomersRiverpod(widget.orgId));
    final selected = widget.selected;

    if (selected != null) {
      // Once chosen, show a compact confirmation rather than leaving a text
      // field the user might edit into a mismatch.
      return InputDecorator(
        decoration: _decoration(provider, suffix: null),
        child: Row(
          children: [
            const Icon(Icons.check_circle, size: 16, color: Color(0xFF2E9E4F)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    selected.displayName,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ZohoPalette.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (selected.bestPhone.isNotEmpty ||
                      selected.email.isNotEmpty)
                    Text(
                      [
                        if (selected.email.isNotEmpty) selected.email,
                        if (selected.bestPhone.isNotEmpty) selected.bestPhone,
                      ].join(' · '),
                      style: const TextStyle(
                          fontSize: 11, color: ZohoPalette.textMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: widget.enabled ? () => widget.onSelected(null) : null,
              child: const Text('Change'),
            ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Autocomplete<ZohoCustomer>(
            initialValue: TextEditingValue(text: widget.initialQuery),
            displayStringForOption: (c) => c.displayName,
            optionsBuilder: (value) {
              final q = value.text.trim().toLowerCase();
              if (q.isEmpty) {
                return provider.customers.take(_maxSuggestions);
              }
              return provider.customers
                  .where((c) =>
                      c.displayName.toLowerCase().contains(q) ||
                      c.companyName.toLowerCase().contains(q) ||
                      c.email.toLowerCase().contains(q) ||
                      c.bestPhone.contains(q))
                  .take(_maxSuggestions);
            },
            onSelected: widget.onSelected,
            fieldViewBuilder: (context, controller, focusNode, onSubmit) {
              return TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: widget.enabled && !provider.isLoading,
                style: const TextStyle(fontSize: 13),
                decoration: _decoration(
                  provider,
                  suffix: provider.isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : const Icon(Icons.search, size: 18),
                ),
              );
            },
            optionsViewBuilder: (context, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(4),
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxHeight: 340, maxWidth: 460),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: options.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: ZohoPalette.border),
                      itemBuilder: (context, i) {
                        final c = options.elementAt(i);
                        return CustomerResultTile(
                          name: c.displayName,
                          subtitle: c.companyName,
                          email: c.email,
                          phone: c.bestPhone,
                          onTap: () => onSelected(c),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: OutlinedButton.icon(
            onPressed: widget.enabled
                ? () => _createNew(widget.newCustomerSeedName.trim().isNotEmpty
                    ? widget.newCustomerSeedName
                    : widget.initialQuery)
                : null,
            icon: const Icon(Icons.person_add, size: 16),
            label: const Text('New'),
            style: OutlinedButton.styleFrom(
              foregroundColor: ZohoPalette.link,
              side: const BorderSide(color: ZohoPalette.border),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  InputDecoration _decoration(ZohoCustomersProvider provider,
      {required Widget? suffix}) {
    return InputDecoration(
      labelText: 'Zoho customer *',
      labelStyle: const TextStyle(fontSize: 13),
      hintText: 'Search by name, company, email or phone',
      hintStyle: const TextStyle(fontSize: 12),
      helperText: provider.error ??
          (provider.customers.isEmpty && !provider.isLoading
              ? 'No customers loaded yet'
              : null),
      helperStyle: TextStyle(
        fontSize: 11,
        color: provider.error != null ? Colors.red : ZohoPalette.textMuted,
      ),
      suffixIcon: suffix,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: ZohoPalette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: ZohoPalette.link),
      ),
    );
  }
}
