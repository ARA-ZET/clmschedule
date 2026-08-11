import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/zoho_customer.dart';
import '../../providers/zoho_customers_provider.dart';
import 'zoho_status_chip.dart';

/// Searchable list of Zoho Books customers, with add/edit.
class ZohoCustomersScreen extends riverpod.ConsumerStatefulWidget {
  const ZohoCustomersScreen({super.key});

  @override
  riverpod.ConsumerState<ZohoCustomersScreen> createState() =>
      _ZohoCustomersScreenState();
}

class _ZohoCustomersScreenState
    extends riverpod.ConsumerState<ZohoCustomersScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Loads on first open rather than in the provider constructor — each load
    // is a rate-limited Zoho call.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(zohoCustomersRiverpod).initialize();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openForm({ZohoCustomer? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _CustomerFormDialog(existing: existing),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(existing == null ? 'Customer created' : 'Customer updated'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(zohoCustomersRiverpod);
    final customers = provider.filteredCustomers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Customers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload from Zoho',
            onPressed: provider.isLoading ? null : provider.refresh,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchController,
              onChanged: provider.setSearchText,
              decoration: InputDecoration(
                hintText: 'Search name, company or email',
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
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.person_add),
        label: const Text('New customer'),
      ),
      body: Column(
        children: [
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
              child: ListView.separated(
                itemCount: customers.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final c = customers[index];
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        c.displayName.isNotEmpty
                            ? c.displayName[0].toUpperCase()
                            : '?',
                      ),
                    ),
                    title: Text(c.displayName),
                    subtitle: Text(
                      [
                        if (c.companyName.isNotEmpty &&
                            c.companyName != c.contactName)
                          c.companyName,
                        if (c.email.isNotEmpty) c.email,
                        if (c.phone.isNotEmpty) c.phone,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: c.outstandingReceivable > 0
                        ? Text(
                            'R ${c.outstandingReceivable.toStringAsFixed(2)}',
                            style: TextStyle(
                              color: Colors.red.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : null,
                    onTap: () => _openForm(existing: c),
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

/// Add/edit form. Zoho requires `contact_name`; everything else is optional.
class _CustomerFormDialog extends riverpod.ConsumerStatefulWidget {
  final ZohoCustomer? existing;

  const _CustomerFormDialog({this.existing});

  @override
  riverpod.ConsumerState<_CustomerFormDialog> createState() =>
      _CustomerFormDialogState();
}

class _CustomerFormDialogState
    extends riverpod.ConsumerState<_CustomerFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _companyController;
  late final TextEditingController _emailController;
  late final TextEditingController _phoneController;

  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.contactName ?? '');
    _companyController = TextEditingController(text: e?.companyName ?? '');
    _emailController = TextEditingController(text: e?.email ?? '');
    _phoneController = TextEditingController(text: e?.phone ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _companyController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
      _error = null;
    });

    final provider = ref.read(zohoCustomersRiverpod);
    final draft = ZohoCustomer(
      contactId: widget.existing?.contactId ?? '',
      contactName: _nameController.text.trim(),
      companyName: _companyController.text.trim(),
      email: _emailController.text.trim(),
      phone: _phoneController.text.trim(),
    );

    try {
      if (widget.existing == null) {
        await provider.createCustomer(draft);
      } else {
        await provider.updateCustomer(draft);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // Never swallowed — the dialog stays open showing why Zoho refused.
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New customer' : 'Edit customer'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Contact name *',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Zoho requires a contact name'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _companyController,
                decoration: const InputDecoration(
                  labelText: 'Company',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
