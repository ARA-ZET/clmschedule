import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../providers/vat_settings_provider.dart';

class VatSettingsDialog extends riverpod.ConsumerStatefulWidget {
  const VatSettingsDialog({super.key});

  @override
  riverpod.ConsumerState<VatSettingsDialog> createState() =>
      _VatSettingsDialogState();
}

class _VatSettingsDialogState
    extends riverpod.ConsumerState<VatSettingsDialog> {
  late final TextEditingController _controller;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final current = ref.read(vatSettingsRiverpod).vatPercentage;
    _controller = TextEditingController(
        text: current == current.truncateToDouble()
            ? current.toInt().toString()
            : current.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = double.tryParse(_controller.text.trim());
    if (value == null || value <= 0 || value > 100) {
      ScaffoldMessenger.of(context).showToast(
        const SnackBar(
          content: Text('Enter a valid VAT percentage (e.g. 15)'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    await ref.read(vatSettingsRiverpod).updateVatPercentage(value);
    if (mounted) {
      setState(() => _isSaving = false);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.percent, size: 22),
          SizedBox(width: 8),
          Text('VAT Settings'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Set the VAT percentage added on top of job amounts. Amounts '
            'are always entered excluding VAT.',
            style: TextStyle(fontSize: 13, color: Colors.black54),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'VAT Percentage',
              border: OutlineInputBorder(),
              suffixText: '%',
              helperText: 'South African standard VAT is 15%',
            ),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
            ],
            autofocus: true,
            onFieldSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
          ),
          child: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
