import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/address_service_v2.dart';

/// Screen for adding addresses to a suburb via copy/paste
class AddSuburbAddressesScreen extends StatefulWidget {
  const AddSuburbAddressesScreen({super.key});

  @override
  State<AddSuburbAddressesScreen> createState() =>
      _AddSuburbAddressesScreenState();
}

class _AddSuburbAddressesScreenState extends State<AddSuburbAddressesScreen> {
  final AddressServiceV2 _addressService =
      AddressServiceV2(FirebaseFirestore.instance);
  final _suburbController = TextEditingController();
  final _addressesController = TextEditingController();

  bool _isLoading = false;
  int _parsedCount = 0;

  @override
  void dispose() {
    _suburbController.dispose();
    _addressesController.dispose();
    super.dispose();
  }

  void _parseAddresses() {
    final text = _addressesController.text.trim();
    if (text.isEmpty) {
      setState(() => _parsedCount = 0);
      return;
    }

    final suburb = _suburbController.text.trim().toLowerCase();
    final addresses = _addressService.parseAddressesFromText(text, suburb);

    setState(() => _parsedCount = addresses.length);
  }

  Future<void> _saveAddresses() async {
    final suburb = _suburbController.text.trim().toLowerCase();
    final text = _addressesController.text.trim();

    if (suburb.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a suburb name')),
      );
      return;
    }

    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please paste addresses')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final addresses = _addressService.parseAddressesFromText(text, suburb);
      await _addressService.setSuburbAddresses(suburb, addresses);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Added ${addresses.length} addresses to $suburb')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Addresses'),
        actions: [
          if (_parsedCount > 0)
            TextButton.icon(
              onPressed: _isLoading ? null : _saveAddresses,
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_isLoading ? 'Saving...' : 'Save'),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add Addresses to Suburb',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),

            // Suburb name
            TextField(
              controller: _suburbController,
              decoration: const InputDecoration(
                labelText: 'Suburb Name',
                hintText: 'e.g., Pinelands',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.location_city),
              ),
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => _parseAddresses(),
            ),

            const SizedBox(height: 24),

            // Instructions
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.blue.shade700),
                        const SizedBox(width: 8),
                        Text(
                          'How to Add Addresses',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '• Paste addresses below (one per line)\n'
                      '• Supported formats:\n'
                      '  - Street Address, Suburb, City, Postal, Province, Country\n'
                      '  - Street Address\\tSuburb\\tCity (tab-separated)\n'
                      '  - Just Street Address (other fields auto-filled)\n'
                      '• Click Parse to preview\n'
                      '• Click Save to add to Firestore',
                      style: TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Paste area
            TextField(
              controller: _addressesController,
              decoration: InputDecoration(
                labelText: 'Paste Addresses Here',
                hintText:
                    '30 RIVERSIDE ROAD, PINELANDS, CAPE TOWN, 7405, Western Cape, South Africa\\n'
                    '19 CULEMBORG 3 MORNINGSIDE STREET, PINELANDS, ...',
                border: const OutlineInputBorder(),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.content_paste),
                      tooltip: 'Paste from Clipboard',
                      onPressed: () async {
                        final data =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        if (data != null && data.text != null) {
                          _addressesController.text = data.text!;
                          _parseAddresses();
                        }
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear',
                      onPressed: () {
                        _addressesController.clear();
                        _parseAddresses();
                      },
                    ),
                  ],
                ),
              ),
              maxLines: 15,
              onChanged: (_) => _parseAddresses(),
            ),

            const SizedBox(height: 16),

            // Parse button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _parseAddresses,
                icon: const Icon(Icons.analytics),
                label: Text(_parsedCount > 0
                    ? 'Parsed: $_parsedCount addresses'
                    : 'Parse Addresses'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                  backgroundColor: _parsedCount > 0 ? Colors.green : null,
                  foregroundColor: _parsedCount > 0 ? Colors.white : null,
                ),
              ),
            ),

            if (_parsedCount > 0) ...[
              const SizedBox(height: 16),
              Card(
                color: Colors.green.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.green.shade700),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Ready to add $_parsedCount addresses to ${_suburbController.text}',
                          style: TextStyle(
                            color: Colors.green.shade900,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
