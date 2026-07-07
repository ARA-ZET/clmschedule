import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../models/payroll_settings.dart';
import '../../providers/payroll_provider.dart';

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
  late TextEditingController _transportFareController;
  late List<_CodeRow> _codeRows;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(payrollRiverpod).settings;
    _dayRateController =
        TextEditingController(text: settings.defaultDayRate.toString());
    _perSetRateController =
        TextEditingController(text: settings.defaultPerSetRate.toString());
    _estimateBonusController = TextEditingController(
        text: settings.defaultEstimateBonus.toString());
    _transportFareController = TextEditingController(
        text: settings.defaultTransportFare.toString());
    _codeRows = [
      for (final code in settings.bonusCodes)
        _CodeRow(
          code: code,
          label: settings.bonusCodeLabels[code] ?? '',
          amount: settings.defaultBonusCodeAmounts[code]?.toString() ?? '',
        ),
    ];
  }

  @override
  void dispose() {
    _dayRateController.dispose();
    _perSetRateController.dispose();
    _estimateBonusController.dispose();
    _transportFareController.dispose();
    for (final row in _codeRows) {
      row.dispose();
    }
    super.dispose();
  }

  void _addCodeRow() => setState(() => _codeRows.add(_CodeRow()));

  void _removeCodeRow(int index) => setState(() {
        _codeRows.removeAt(index).dispose();
      });

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

    final updated = PayrollSettings(
      defaultDayRate: double.tryParse(_dayRateController.text.trim()) ?? 0,
      defaultBonusCodeAmounts: bonusCodeAmounts,
      bonusCodeLabels: bonusCodeLabels,
      bonusCodes: bonusCodes,
      defaultPerSetRate:
          double.tryParse(_perSetRateController.text.trim()) ?? 0,
      defaultEstimateBonus:
          double.tryParse(_estimateBonusController.text.trim()) ?? 0,
      defaultTransportFare:
          double.tryParse(_transportFareController.text.trim()) ?? 0,
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
              const SizedBox(height: 12),
              TextField(
                controller: _transportFareController,
                decoration: const InputDecoration(
                    labelText: 'Default transport fare per trip (R)'),
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
                          decoration:
                              const InputDecoration(labelText: 'Code'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _codeRows[i].label,
                          decoration:
                              const InputDecoration(labelText: 'Label'),
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
