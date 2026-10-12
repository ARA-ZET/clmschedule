import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/zoho_customer.dart';
import '../../providers/zoho_customers_provider.dart';
import 'zoho_table.dart';

/// Add/edit form. Zoho requires `contact_name`; everything else is optional.
class CustomerFormDialog extends riverpod.ConsumerStatefulWidget {
  final ZohoCustomer? existing;

  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  const CustomerFormDialog({super.key, required this.orgId, this.existing});

  @override
  riverpod.ConsumerState<CustomerFormDialog> createState() =>
      CustomerFormDialogState();
}

class CustomerFormDialogState
    extends riverpod.ConsumerState<CustomerFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _companyController;
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _emailController;
  late final TextEditingController _phoneController;
  late final TextEditingController _mobileController;

  bool _isSaving = false;
  String? _error;

  /// Whether this edits a contact that already exists in Zoho.
  ///
  /// Keyed on the contact id via [ZohoCustomer.existsInZoho], **not** on
  /// `existing != null` — the job dialog's picker seeds this form with a
  /// name-only customer for a brand-new contact.
  bool get _isEdit => widget.existing?.existsInZoho ?? false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.contactName ?? '');
    _companyController = TextEditingController(text: e?.companyName ?? '');
    _firstNameController = TextEditingController(text: e?.firstName ?? '');
    _lastNameController = TextEditingController(text: e?.lastName ?? '');
    _emailController = TextEditingController(text: e?.email ?? '');
    _phoneController = TextEditingController(text: e?.phone ?? '');
    _mobileController = TextEditingController(text: e?.mobile ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _companyController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
      _error = null;
    });

    final provider = ref.read(zohoCustomersRiverpod(widget.orgId));
    final existing = widget.existing;
    final draft = ZohoCustomer(
      contactId: existing?.contactId ?? '',
      contactName: _nameController.text.trim(),
      companyName: _companyController.text.trim(),
      firstName: _firstNameController.text.trim(),
      lastName: _lastNameController.text.trim(),
      email: _emailController.text.trim(),
      phone: _phoneController.text.trim(),
      mobile: _mobileController.text.trim(),
      // Preserved rather than defaulted, so saving an existing contact does
      // not silently flip it between business and individual.
      salutation: existing?.salutation ?? '',
      customerSubType: existing?.customerSubType ?? 'business',
      primaryContactPersonId: existing?.primaryContactPersonId ?? '',
    );

    try {
      // Pops the saved customer (not just a bool) so callers that need to
      // select it immediately — like the job dialog's picker — can.
      final saved = _isEdit
          ? await provider.updateCustomer(draft)
          : await provider.createCustomer(draft);
      if (mounted) Navigator.of(context).pop(saved);
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

  InputDecoration _fieldDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 13),
      isDense: true,
      filled: true,
      fillColor: ZohoPalette.surface,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: ZohoPalette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: ZohoPalette.link),
      ),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: ZohoPalette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      title: Text(
        _isEdit ? 'Edit Customer' : 'New Customer',
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: ZohoPalette.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: _fieldDecoration('Contact name *'),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Zoho requires a contact name'
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _companyController,
                style: const TextStyle(fontSize: 13),
                decoration: _fieldDecoration('Company'),
              ),
              const SizedBox(height: 14),
              // First/last name and the contact details below all belong to
              // Zoho's primary contact person, not the contact itself.
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _firstNameController,
                      style: const TextStyle(fontSize: 13),
                      decoration: _fieldDecoration('First name'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lastNameController,
                      style: const TextStyle(fontSize: 13),
                      decoration: _fieldDecoration('Last name'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(fontSize: 13),
                decoration: _fieldDecoration('Email'),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(fontSize: 13),
                      decoration: _fieldDecoration('Work phone'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _mobileController,
                      keyboardType: TextInputType.phone,
                      style: const TextStyle(fontSize: 13),
                      decoration: _fieldDecoration('Mobile'),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ZohoNewButton(
          label: _isSaving ? 'Saving…' : 'Save',
          icon: null,
          onPressed: _isSaving ? null : _save,
        ),
      ],
    );
  }
}
