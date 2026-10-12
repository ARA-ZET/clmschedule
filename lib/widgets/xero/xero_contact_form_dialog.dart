import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/xero_contact.dart';
import '../../services/xero_accounting_service.dart';
import '../zoho/zoho_table.dart';

/// Create or edit a Xero contact.
///
/// Returns the saved [XeroContact] — with its real `ContactID` — or null if
/// the user cancelled. The create-vs-update decision keys on
/// [XeroContact.existsInXero], never on "was I handed an object": the picker
/// seeds this dialog with a name-only contact to pre-fill a *new* one, and
/// treating that as an edit would send an update for a contact Xero has never
/// heard of.
Future<XeroContact?> showXeroContactFormDialog(
  BuildContext context, {
  XeroContact? existing,
  String seedName = '',
}) {
  return showDialog<XeroContact>(
    context: context,
    barrierDismissible: false,
    builder: (_) => XeroContactFormDialog(
      existing: existing,
      seedName: seedName,
    ),
  );
}

class XeroContactFormDialog extends riverpod.ConsumerStatefulWidget {
  final XeroContact? existing;
  final String seedName;

  const XeroContactFormDialog({
    super.key,
    this.existing,
    this.seedName = '',
  });

  @override
  riverpod.ConsumerState<XeroContactFormDialog> createState() =>
      _XeroContactFormDialogState();
}

class _XeroContactFormDialogState
    extends riverpod.ConsumerState<XeroContactFormDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _mobile;

  bool _isSaving = false;
  String? _error;

  /// Set when Xero rejected the name as already taken. Kept separate from
  /// [_error] because it is the one failure with a specific fix — change the
  /// name, or go and use the contact that already has it.
  bool _duplicateName = false;

  bool get _isEdit => widget.existing?.existsInXero ?? false;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    _name = TextEditingController(
      text: (c?.name.isNotEmpty ?? false) ? c!.name : widget.seedName,
    );
    _firstName = TextEditingController(text: c?.firstName ?? '');
    _lastName = TextEditingController(text: c?.lastName ?? '');
    _email = TextEditingController(text: c?.emailAddress ?? '');
    _phone = TextEditingController(text: c?.phone ?? '');
    _mobile = TextEditingController(text: c?.mobile ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _phone.dispose();
    _mobile.dispose();
    super.dispose();
  }

  XeroContact _build() {
    final base = widget.existing;
    return XeroContact(
      // Empty on a create, which is what makes Xero treat it as one.
      contactId: base?.contactId ?? '',
      name: _name.text.trim(),
      firstName: _firstName.text.trim(),
      lastName: _lastName.text.trim(),
      emailAddress: _email.text.trim(),
      phone: _phone.text.trim(),
      mobile: _mobile.text.trim(),
      status: base?.status ?? 'ACTIVE',
      defaultCurrency: base?.defaultCurrency ?? '',
      outstandingReceivable: base?.outstandingReceivable ?? 0.0,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
      _error = null;
      _duplicateName = false;
    });

    final service = ref.read(xeroAccountingServiceRiverpod);
    try {
      final contact = _build();
      final saved = _isEdit
          ? await service.updateContact(contact)
          : await service.createContact(contact);

      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } on XeroException catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        // Xero requires contact names to be unique across the whole
        // organisation, which bites the moment the same client is billed for a
        // second area — the seed name is "client, area".
        _duplicateName = e.isDuplicateName;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: ZohoPalette.surface,
      title: Text(_isEdit ? 'Edit customer' : 'New customer'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _field(
                  controller: _name,
                  label: 'Name *',
                  helper: 'Must be unique across the whole Xero organisation.',
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'A name is required'
                      : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                        child: _field(
                            controller: _firstName, label: 'First name')),
                    const SizedBox(width: 10),
                    Expanded(
                        child:
                            _field(controller: _lastName, label: 'Last name')),
                  ],
                ),
                const SizedBox(height: 12),
                _field(
                  controller: _email,
                  label: 'Email',
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) {
                    final s = v?.trim() ?? '';
                    if (s.isEmpty) return null;
                    // Deliberately loose: Xero does its own validation, and a
                    // strict pattern here would reject addresses it accepts.
                    return s.contains('@')
                        ? null
                        : 'That does not look like an email';
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                        child: _field(
                            controller: _phone,
                            label: 'Phone',
                            keyboardType: TextInputType.phone)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: _field(
                            controller: _mobile,
                            label: 'Mobile',
                            keyboardType: TextInputType.phone)),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      border: Border.all(color: Colors.red.shade200),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline,
                            size: 16, color: Colors.red.shade700),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _duplicateName
                                ? 'A customer called "${_name.text.trim()}" '
                                    'already exists in Xero. Names must be '
                                    'unique across the organisation — either '
                                    'change it, or close this and search for '
                                    'the existing customer instead of creating '
                                    'a second one.'
                                : _error!,
                            style: TextStyle(
                                fontSize: 12, color: Colors.red.shade900),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
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
              : Text(_isEdit ? 'Save changes' : 'Create in Xero'),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? helper,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      enabled: !_isSaving,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        labelStyle: const TextStyle(fontSize: 12),
        helperStyle: const TextStyle(fontSize: 11),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
      ),
    );
  }
}
