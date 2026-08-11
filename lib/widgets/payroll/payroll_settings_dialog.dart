import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:image_picker/image_picker.dart';

import '../../models/payroll_settings.dart';
import '../../providers/payroll_provider.dart';
import '../../services/storage_upload.dart';

/// Edits the company-wide default payroll rates (`payrollSettings/config`).
/// Per-distributor overrides live on the distributor's own edit dialog.
class PayrollSettingsDialog extends riverpod.ConsumerStatefulWidget {
  const PayrollSettingsDialog({super.key});

  @override
  riverpod.ConsumerState<PayrollSettingsDialog> createState() =>
      _PayrollSettingsDialogState();
}

class _CodeRow {
  final TextEditingController code;
  final TextEditingController label;
  final TextEditingController amount;

  _CodeRow({String code = '', String label = '', String amount = ''})
      : code = TextEditingController(text: code),
        label = TextEditingController(text: label),
        amount = TextEditingController(text: amount);

  void dispose() {
    code.dispose();
    label.dispose();
    amount.dispose();
  }
}

class _PayrollSettingsDialogState
    extends riverpod.ConsumerState<PayrollSettingsDialog> {
  late TextEditingController _dayRateController;
  late TextEditingController _perSetRateController;
  late TextEditingController _estimateBonusController;
  late List<_CodeRow> _codeRows;
  bool _saving = false;

  // ── Company details state ───────────────────────────────────────────────
  late TextEditingController _companyNameController;
  late TextEditingController _companyRegistrationNoController;
  late TextEditingController _companyVatNoController;
  late TextEditingController _companyAddressController;
  late TextEditingController _companyPhoneController;
  late TextEditingController _companyEmailController;
  Uint8List? _pendingLogoBytes;
  String? _pendingLogoFileName;
  String? _previewLogoUrl;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(payrollRiverpod).settings;
    _dayRateController =
        TextEditingController(text: settings.defaultDayRate.toString());
    _perSetRateController =
        TextEditingController(text: settings.defaultPerSetRate.toString());
    _estimateBonusController =
        TextEditingController(text: settings.defaultEstimateBonus.toString());
    _codeRows = [
      for (final code in settings.bonusCodes)
        _CodeRow(
          code: code,
          label: settings.bonusCodeLabels[code] ?? '',
          amount: settings.defaultBonusCodeAmounts[code]?.toString() ?? '',
        ),
    ];

    _companyNameController = TextEditingController(text: settings.companyName);
    _companyRegistrationNoController =
        TextEditingController(text: settings.companyRegistrationNo);
    _companyVatNoController =
        TextEditingController(text: settings.companyVatNo);
    _companyAddressController =
        TextEditingController(text: settings.companyAddress);
    _companyPhoneController =
        TextEditingController(text: settings.companyPhone);
    _companyEmailController =
        TextEditingController(text: settings.companyEmail);
    _previewLogoUrl = settings.companyLogoUrl;
  }

  @override
  void dispose() {
    _dayRateController.dispose();
    _perSetRateController.dispose();
    _estimateBonusController.dispose();
    for (final row in _codeRows) {
      row.dispose();
    }
    _companyNameController.dispose();
    _companyRegistrationNoController.dispose();
    _companyVatNoController.dispose();
    _companyAddressController.dispose();
    _companyPhoneController.dispose();
    _companyEmailController.dispose();
    super.dispose();
  }

  void _addCodeRow() => setState(() => _codeRows.add(_CodeRow()));

  void _removeCodeRow(int index) => setState(() {
        _codeRows.removeAt(index).dispose();
      });

  Future<void> _pickLogo() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 90,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _pendingLogoBytes = bytes;
      _pendingLogoFileName = picked.name;
      _previewLogoUrl = null; // show the local memory preview instead
    });
  }

  Future<String?> _uploadLogo() async {
    if (_pendingLogoBytes == null) return null;
    final ext =
        (_pendingLogoFileName ?? 'logo.png').split('.').last.toLowerCase();
    final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
    final ref = FirebaseStorage.instance.ref().child('company/logo.$ext');
    await StorageUpload.safePutData(
      ref,
      _pendingLogoBytes!,
      metadata: SettableMetadata(contentType: contentType),
    );
    return await ref.getDownloadURL();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final bonusCodes = <String>[];
    final bonusCodeLabels = <String, String>{};
    final bonusCodeAmounts = <String, double>{};
    for (final row in _codeRows) {
      final code = row.code.text.trim().toUpperCase();
      if (code.isEmpty) continue;
      bonusCodes.add(code);
      bonusCodeLabels[code] = row.label.text.trim();
      bonusCodeAmounts[code] = double.tryParse(row.amount.text.trim()) ?? 0;
    }

    String? logoUrl = ref.read(payrollRiverpod).settings.companyLogoUrl;
    if (_pendingLogoBytes != null) {
      try {
        logoUrl = await _uploadLogo();
      } catch (e) {
        setState(() => _saving = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Logo upload failed: $e'),
                backgroundColor: Colors.red),
          );
        }
        return;
      }
    }

    final updated = PayrollSettings(
      defaultDayRate: double.tryParse(_dayRateController.text.trim()) ?? 0,
      defaultBonusCodeAmounts: bonusCodeAmounts,
      bonusCodeLabels: bonusCodeLabels,
      bonusCodes: bonusCodes,
      defaultPerSetRate:
          double.tryParse(_perSetRateController.text.trim()) ?? 0,
      defaultEstimateBonus:
          double.tryParse(_estimateBonusController.text.trim()) ?? 0,
      companyName: _companyNameController.text.trim(),
      companyRegistrationNo: _companyRegistrationNoController.text.trim(),
      companyVatNo: _companyVatNoController.text.trim(),
      companyAddress: _companyAddressController.text.trim(),
      companyPhone: _companyPhoneController.text.trim(),
      companyEmail: _companyEmailController.text.trim(),
      companyLogoUrl: logoUrl,
    );

    await ref.read(payrollRiverpod).updateSettings(updated);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Payroll settings'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Company details',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                'Shown on payslips and other printed documents.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _LogoPreview(
                    bytes: _pendingLogoBytes,
                    url: _previewLogoUrl,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextButton.icon(
                          onPressed: _pickLogo,
                          icon: const Icon(Icons.image_outlined, size: 18),
                          label: const Text('Change logo'),
                        ),
                        const Text(
                          'PNG/JPG, square works best',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _companyNameController,
                decoration: const InputDecoration(labelText: 'Company name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _companyAddressController,
                decoration: const InputDecoration(
                  labelText: 'Office address',
                  helperText: 'One line per address line',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _companyPhoneController,
                decoration: const InputDecoration(labelText: 'Contact phone'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _companyEmailController,
                decoration: const InputDecoration(labelText: 'Contact email'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _companyRegistrationNoController,
                      decoration: const InputDecoration(
                          labelText: 'Registration number'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _companyVatNoController,
                      decoration:
                          const InputDecoration(labelText: 'VAT number'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 8),
              const Text('Wage rates',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(
                controller: _dayRateController,
                decoration:
                    const InputDecoration(labelText: 'Default day rate (R)'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _perSetRateController,
                decoration: const InputDecoration(
                    labelText: 'Default per-set rate (R)'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _estimateBonusController,
                decoration: const InputDecoration(
                    labelText: 'Default estimate-reached bonus (R)'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Special day-type codes',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add code',
                    onPressed: _addCodeRow,
                  ),
                ],
              ),
              for (var i = 0; i < _codeRows.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 70,
                        child: TextField(
                          controller: _codeRows[i].code,
                          decoration: const InputDecoration(labelText: 'Code'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _codeRows[i].label,
                          decoration: const InputDecoration(labelText: 'Label'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: _codeRows[i].amount,
                          decoration:
                              const InputDecoration(labelText: 'Bonus (R)'),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true, signed: true),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Remove code',
                        onPressed: () => _removeCodeRow(i),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
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

/// Small square preview of the company logo — a freshly picked local image
/// takes priority, then the saved network URL, then a generic placeholder.
class _LogoPreview extends StatelessWidget {
  final Uint8List? bytes;
  final String? url;

  const _LogoPreview({required this.bytes, required this.url});

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (bytes != null) {
      child = Image.memory(bytes!, fit: BoxFit.cover);
    } else if (url != null && url!.isNotEmpty) {
      child = Image.network(
        url!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.business, color: Colors.grey),
      );
    } else {
      child = const Icon(Icons.business, color: Colors.grey);
    }
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
