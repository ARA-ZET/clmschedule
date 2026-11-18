import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/company.dart';
import '../providers/company_provider.dart';
import '../providers/job_type_provider.dart';
import 'xero/xero_company_config.dart';
import 'zoho/zoho_company_config.dart';

/// Manage the businesses whose work this app handles, and which accounting
/// system each one invoices through.
///
/// Companies are the single source of truth for job-type ownership. Adding one
/// here plus assigning job types to it is all that is needed — no code change.
class CompanyManagementDialog extends riverpod.ConsumerStatefulWidget {
  const CompanyManagementDialog({super.key});

  @override
  riverpod.ConsumerState<CompanyManagementDialog> createState() =>
      _CompanyManagementDialogState();
}

class _CompanyManagementDialogState
    extends riverpod.ConsumerState<CompanyManagementDialog> {
  final _nameController = TextEditingController();
  final _shortNameController = TextEditingController();

  String? _editingId;
  bool _isAdding = false;
  AccountingProvider _provider = AccountingProvider.none;
  bool _active = true;

  /// Provider-specific settings, now editable for Xero. Held in state so the
  /// dropdowns can change it before the save writes it back.
  Map<String, String> _providerConfig = const {};

  @override
  void dispose() {
    _nameController.dispose();
    _shortNameController.dispose();
    super.dispose();
  }

  void _startAdd() {
    setState(() {
      _isAdding = true;
      _editingId = null;
      _nameController.clear();
      _shortNameController.clear();
      _provider = AccountingProvider.none;
      _providerConfig = const {};
      _active = true;
    });
  }

  void _startEdit(Company company) {
    setState(() {
      _isAdding = false;
      _editingId = company.id;
      _nameController.text = company.name;
      _shortNameController.text = company.shortName;
      _provider = company.accountingProvider;
      _providerConfig = Map<String, String>.from(company.providerConfig);
      _active = company.active;
    });
  }

  void _cancelEdit() {
    setState(() {
      _isAdding = false;
      _editingId = null;
      _nameController.clear();
      _shortNameController.clear();
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(content: Text('Please enter a company name')),
      );
      return;
    }

    final provider = ref.read(companyRiverpod);
    final existing = _editingId == null ? null : provider.getById(_editingId!);

    final company = Company(
      // Empty id on add — the provider lets Firestore generate one.
      id: _editingId ?? '',
      name: name,
      shortName: _shortNameController.text.trim(),
      accountingProvider: _provider,
      // Xero's settings are edited here; anything else a provider stored is
      // carried through untouched rather than dropped.
      providerConfig: {
        ...?existing?.providerConfig,
        ..._providerConfig,
      },
      colorValue: existing?.colorValue,
      order: existing?.order ?? provider.companies.length,
      active: _active,
    );

    try {
      await provider.saveCompany(company);
      if (mounted) _cancelEdit();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showToast(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// How many job types point at a company — shown so deactivating one is an
  /// informed choice rather than a surprise.
  int _jobTypeCount(String companyId) {
    final types = ref.read(jobTypeRiverpod).jobTypes;
    return types.where((t) => t.resolvedCompanyId == companyId).length;
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(companyRiverpod);
    final editing = _isAdding || _editingId != null;

    return AlertDialog(
      title: const Text('Companies'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Each job type belongs to one company, and the company decides '
                'which accounting system its jobs are invoiced through.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 14),
              if (provider.isLoading && provider.companies.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final c in provider.companies)
                        ListTile(
                          dense: true,
                          leading: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: c.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          title: Text(
                            c.name,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              decoration:
                                  c.active ? null : TextDecoration.lineThrough,
                            ),
                          ),
                          subtitle: Text(
                            '${c.accountingProvider.label}'
                            '${c.accountingProvider.isImplemented ? '' : ' · not built yet'}'
                            ' · ${_jobTypeCount(c.id)} job types',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, size: 18),
                                tooltip: 'Edit',
                                onPressed: () => _startEdit(c),
                              ),
                              // Deactivate, never delete: job types and
                              // historical jobs reference companies by id.
                              IconButton(
                                icon: Icon(
                                  c.active
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  size: 18,
                                ),
                                tooltip: c.active ? 'Deactivate' : 'Reactivate',
                                onPressed: () =>
                                    provider.setActive(c.id, !c.active),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              if (!editing)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _startAdd,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add company'),
                  ),
                )
              else ...[
                const Divider(),
                Text(
                  _isAdding ? 'New company' : 'Edit company',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Company name',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _shortNameController,
                  decoration: const InputDecoration(
                    labelText: 'Short name',
                    helperText: 'Used on chips and column labels, e.g. CLM',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<AccountingProvider>(
                  initialValue: _provider,
                  decoration: const InputDecoration(
                    labelText: 'Accounting provider',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: AccountingProvider.values
                      .map((p) => DropdownMenuItem(
                            value: p,
                            child: Text(p.isImplemented
                                ? p.label
                                : '${p.label} (not built yet)'),
                          ))
                      .toList(),
                  onChanged: (p) =>
                      setState(() => _provider = p ?? AccountingProvider.none),
                ),
                if (_provider == AccountingProvider.zoho)
                  ZohoCompanyConfig(
                    // Keyed so switching between companies re-reads the org.
                    key: ValueKey('zoho-${_editingId ?? 'new'}'),
                    companyId: _editingId ?? '',
                    config: _providerConfig,
                    onChanged: (next) =>
                        setState(() => _providerConfig = next),
                  ),
                if (_provider == AccountingProvider.xero)
                  XeroCompanyConfig(
                    config: _providerConfig,
                    onChanged: (next) =>
                        setState(() => _providerConfig = next),
                  ),
                if (!_provider.isImplemented)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'Jobs will be tagged with this provider, but the app '
                      'cannot raise invoices for it yet — handle those '
                      'manually until it is built.',
                      style: TextStyle(fontSize: 11, color: Colors.orange),
                    ),
                  ),
                SwitchListTile(
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                  title: const Text('Active'),
                  subtitle: const Text('Inactive companies stay linked to '
                      'existing job types but are not offered for new ones'),
                  contentPadding: EdgeInsets.zero,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _cancelEdit,
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _save,
                      child: Text(_isAdding ? 'Add' : 'Save'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
