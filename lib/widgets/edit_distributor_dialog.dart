import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:image_picker/image_picker.dart';
import '../models/distributor.dart';
import '../models/distributor_payroll_profile.dart';
import '../models/payroll_settings.dart';
import '../providers/payroll_provider.dart';
import '../services/storage_upload.dart';

class EditDistributorDialog extends riverpod.ConsumerStatefulWidget {
  final Distributor distributor;
  final int totalDistributors;

  const EditDistributorDialog({
    super.key,
    required this.distributor,
    required this.totalDistributors,
  });

  @override
  riverpod.ConsumerState<EditDistributorDialog> createState() =>
      _EditDistributorDialogState();
}

class _EditDistributorDialogState
    extends riverpod.ConsumerState<EditDistributorDialog> {
  late TextEditingController _nameController;
  late TextEditingController _indexController;
  late TextEditingController _phone1Controller;
  late TextEditingController _phone2Controller;
  late DistributorStatus _selectedStatus;
  late DistributorRole _selectedRole;
  final _formKey = GlobalKey<FormState>();

  // Image upload state
  Uint8List? _pendingImageBytes;
  String? _pendingImageFileName;
  String? _previewImageUrl; // current or newly picked
  bool _uploading = false;

  // ── Payroll section state ──────────────────────────────────────────────
  PayrollSettings _payrollSettings = PayrollSettings.defaults();
  late TextEditingController _dayRateController;
  late TextEditingController _perSetRateController;
  late TextEditingController _estimateBonusController;
  late TextEditingController _transportFareController;
  late bool _transportEligible;
  late Map<String, TextEditingController> _bonusCodeControllers;
  late TextEditingController _bankNameController;
  late TextEditingController _bankAccountHolderController;
  late TextEditingController _bankAccountNumberController;
  late TextEditingController _bankBranchCodeController;
  late TextEditingController _bankAccountTypeController;
  late String _paymentMethod;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.distributor.name);
    _indexController =
        TextEditingController(text: widget.distributor.index.toString());
    _phone1Controller =
        TextEditingController(text: widget.distributor.phone1 ?? '');
    _phone2Controller =
        TextEditingController(text: widget.distributor.phone2 ?? '');
    _selectedStatus = widget.distributor.status;
    _selectedRole = widget.distributor.role;
    _previewImageUrl = widget.distributor.imageUrl;

    final payroll = widget.distributor.payroll;
    _dayRateController =
        TextEditingController(text: payroll?.dayRate?.toString() ?? '');
    _perSetRateController =
        TextEditingController(text: payroll?.perSetRate?.toString() ?? '');
    _estimateBonusController =
        TextEditingController(text: payroll?.estimateBonus?.toString() ?? '');
    _transportFareController = TextEditingController(
        text: payroll?.transportFarePerTrip?.toString() ?? '');
    _transportEligible = payroll?.transportEligible ?? false;
    _bonusCodeControllers = {
      for (final code in _payrollSettings.bonusCodes)
        code: TextEditingController(
            text: payroll?.bonusCodeAmounts[code]?.toString() ?? ''),
    };
    _bankNameController =
        TextEditingController(text: payroll?.bankName ?? '');
    _bankAccountHolderController =
        TextEditingController(text: payroll?.bankAccountHolder ?? '');
    _bankAccountNumberController =
        TextEditingController(text: payroll?.bankAccountNumber ?? '');
    _bankBranchCodeController =
        TextEditingController(text: payroll?.bankBranchCode ?? '');
    _bankAccountTypeController =
        TextEditingController(text: payroll?.bankAccountType ?? '');
    _paymentMethod = payroll?.paymentMethod ?? 'EFT';

    ref.read(payrollServiceRiverpod).getSettings().then((settings) {
      if (!mounted) return;
      setState(() {
        _payrollSettings = settings;
        // Add controllers for any codes not already covered above.
        for (final code in settings.bonusCodes) {
          _bonusCodeControllers.putIfAbsent(
            code,
            () => TextEditingController(
                text: payroll?.bonusCodeAmounts[code]?.toString() ?? ''),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _indexController.dispose();
    _phone1Controller.dispose();
    _phone2Controller.dispose();
    _dayRateController.dispose();
    _perSetRateController.dispose();
    _estimateBonusController.dispose();
    _transportFareController.dispose();
    for (final c in _bonusCodeControllers.values) {
      c.dispose();
    }
    _bankNameController.dispose();
    _bankAccountHolderController.dispose();
    _bankAccountNumberController.dispose();
    _bankBranchCodeController.dispose();
    _bankAccountTypeController.dispose();
    super.dispose();
  }

  DistributorPayrollProfile _buildPayrollProfile() {
    final bonusOverrides = <String, double>{};
    for (final entry in _bonusCodeControllers.entries) {
      final parsed = double.tryParse(entry.value.text.trim());
      if (parsed != null) bonusOverrides[entry.key] = parsed;
    }
    return DistributorPayrollProfile(
      dayRate: double.tryParse(_dayRateController.text.trim()),
      bonusCodeAmounts: bonusOverrides,
      perSetRate: double.tryParse(_perSetRateController.text.trim()),
      estimateBonus: double.tryParse(_estimateBonusController.text.trim()),
      transportEligible: _transportEligible,
      transportFarePerTrip:
          double.tryParse(_transportFareController.text.trim()),
      bankName: _bankNameController.text.trim().isEmpty
          ? null
          : _bankNameController.text.trim(),
      bankAccountHolder: _bankAccountHolderController.text.trim().isEmpty
          ? null
          : _bankAccountHolderController.text.trim(),
      bankAccountNumber: _bankAccountNumberController.text.trim().isEmpty
          ? null
          : _bankAccountNumberController.text.trim(),
      bankBranchCode: _bankBranchCodeController.text.trim().isEmpty
          ? null
          : _bankBranchCodeController.text.trim(),
      bankAccountType: _bankAccountTypeController.text.trim().isEmpty
          ? null
          : _bankAccountTypeController.text.trim(),
      paymentMethod: _paymentMethod,
    );
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _pendingImageBytes = bytes;
      _pendingImageFileName = picked.name;
      // Show a local memory preview while the image hasn't been uploaded yet
      _previewImageUrl = null;
    });
  }

  Future<String?> _uploadImage(String distributorId) async {
    if (_pendingImageBytes == null) return null;
    final ext =
        (_pendingImageFileName ?? 'photo.jpg').split('.').last.toLowerCase();
    final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
    final ref = FirebaseStorage.instance
        .ref()
        .child('distributor_photos/$distributorId.$ext');
    await StorageUpload.safePutData(
      ref,
      _pendingImageBytes!,
      metadata: SettableMetadata(contentType: contentType),
    );
    return await ref.getDownloadURL();
  }

  IconData _getStatusIcon(DistributorStatus status) {
    switch (status) {
      case DistributorStatus.active:
        return Icons.check_circle;
      case DistributorStatus.inactive:
        return Icons.cancel;
      case DistributorStatus.suspended:
        return Icons.block;
      case DistributorStatus.onLeave:
        return Icons.flight_takeoff;
    }
  }

  Color _getStatusColor(DistributorStatus status) {
    switch (status) {
      case DistributorStatus.active:
        return Colors.green;
      case DistributorStatus.inactive:
        return Colors.grey;
      case DistributorStatus.suspended:
        return Colors.red;
      case DistributorStatus.onLeave:
        return Colors.orange;
    }
  }

  Widget _buildPayrollSection() {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Payroll'),
        leading: const Icon(Icons.payments_outlined),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          TextFormField(
            controller: _dayRateController,
            decoration: InputDecoration(
              labelText: 'Day rate override',
              hintText: 'Company default: R${_payrollSettings.defaultDayRate}',
              prefixIcon: const Icon(Icons.attach_money),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _perSetRateController,
            decoration: InputDecoration(
              labelText: 'Per-set rate override',
              hintText:
                  'Company default: R${_payrollSettings.defaultPerSetRate}',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _estimateBonusController,
            decoration: InputDecoration(
              labelText: 'Estimate-reached bonus override',
              hintText:
                  'Company default: R${_payrollSettings.defaultEstimateBonus}',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Transport eligible'),
            subtitle: const Text('Adds a weekly transport-fare deduction'),
            value: _transportEligible,
            onChanged: (v) => setState(() => _transportEligible = v),
          ),
          if (_transportEligible)
            TextFormField(
              controller: _transportFareController,
              decoration: InputDecoration(
                labelText: 'Fare per trip override',
                hintText:
                    'Company default: R${_payrollSettings.defaultTransportFare}',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
          const SizedBox(height: 16),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Bonus code overrides',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final code in _payrollSettings.bonusCodes)
                SizedBox(
                  width: 140,
                  child: TextFormField(
                    controller: _bonusCodeControllers[code],
                    decoration: InputDecoration(
                      labelText: code,
                      hintText: '${_payrollSettings.defaultBonusCodeAmounts[code] ?? 0}',
                      isDense: true,
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true, signed: true),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Bank details',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _bankNameController,
            decoration: const InputDecoration(labelText: 'Bank name'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _bankAccountHolderController,
            decoration: const InputDecoration(labelText: 'Account holder'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _bankAccountNumberController,
            decoration: const InputDecoration(labelText: 'Account number'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _bankBranchCodeController,
            decoration: const InputDecoration(labelText: 'Branch code'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _bankAccountTypeController,
            decoration: const InputDecoration(
                labelText: 'Account type (e.g. Savings)'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _paymentMethod,
            decoration: const InputDecoration(labelText: 'Payment method'),
            items: const [
              DropdownMenuItem(value: 'EFT', child: Text('EFT')),
              DropdownMenuItem(value: 'Cash', child: Text('Cash')),
              DropdownMenuItem(value: 'Other', child: Text('Other')),
            ],
            onChanged: (v) => setState(() => _paymentMethod = v ?? 'EFT'),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoSection() {
    ImageProvider? imageProvider;
    if (_pendingImageBytes != null) {
      imageProvider = MemoryImage(_pendingImageBytes!);
    } else if (_previewImageUrl != null && _previewImageUrl!.isNotEmpty) {
      imageProvider = NetworkImage(_previewImageUrl!);
    }

    return Column(
      children: [
        GestureDetector(
          onTap: _pickImage,
          child: Stack(
            alignment: Alignment.bottomRight,
            children: [
              CircleAvatar(
                radius: 50,
                backgroundImage: imageProvider,
                backgroundColor: Colors.grey.shade200,
                child: imageProvider == null
                    ? const Icon(Icons.person, size: 48, color: Colors.grey)
                    : null,
              ),
              Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF1565C0),
                ),
                padding: const EdgeInsets.all(6),
                child:
                    const Icon(Icons.camera_alt, size: 16, color: Colors.white),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: _pickImage,
          icon: const Icon(Icons.photo_library, size: 16),
          label: Text(
            imageProvider == null ? 'Add photo' : 'Change photo',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Distributor'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Profile photo ──────────────────────────────────────────
                _buildPhotoSection(),
                const SizedBox(height: 16),

                // ── Name ──────────────────────────────────────────────────
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Distributor Name',
                    hintText: 'Enter distributor name',
                    prefixIcon: Icon(Icons.person),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a distributor name';
                    }
                    if (value.trim().length < 2) {
                      return 'Name must be at least 2 characters long';
                    }
                    return null;
                  },
                  autofocus: true,
                ),
                const SizedBox(height: 16),

                // ── Position index ─────────────────────────────────────────
                TextFormField(
                  controller: _indexController,
                  decoration: InputDecoration(
                    labelText: 'Position Index',
                    hintText:
                        'Enter position (0 to ${widget.totalDistributors - 1})',
                    prefixIcon: const Icon(Icons.format_list_numbered),
                    helperText: 'Position in the list (0 is first)',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a position index';
                    }
                    final index = int.tryParse(value);
                    if (index == null) {
                      return 'Please enter a valid number';
                    }
                    if (index < 0 || index >= widget.totalDistributors) {
                      return 'Index must be between 0 and ${widget.totalDistributors - 1}';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // ── Phone 1 ────────────────────────────────────────────────
                TextFormField(
                  controller: _phone1Controller,
                  decoration: const InputDecoration(
                    labelText: 'Phone 1 (Primary)',
                    hintText: 'Enter primary phone number',
                    prefixIcon: Icon(Icons.phone),
                  ),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 16),

                // ── Phone 2 ────────────────────────────────────────────────
                TextFormField(
                  controller: _phone2Controller,
                  decoration: const InputDecoration(
                    labelText: 'Phone 2 (Secondary)',
                    hintText: 'Enter secondary phone number (optional)',
                    prefixIcon: Icon(Icons.phone_android),
                  ),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 16),

                // ── Role ───────────────────────────────────────────────────
                DropdownButtonFormField<DistributorRole>(
                  initialValue: _selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Role (ID card)',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  items: DistributorRole.values.map((role) {
                    return DropdownMenuItem(
                      value: role,
                      child: Text(role.displayName),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() => _selectedRole = value!);
                  },
                ),
                const SizedBox(height: 16),

                // ── Status ─────────────────────────────────────────────────
                DropdownButtonFormField<DistributorStatus>(
                  initialValue: _selectedStatus,
                  decoration: const InputDecoration(
                    labelText: 'Status',
                    prefixIcon: Icon(Icons.work_outline),
                  ),
                  items: DistributorStatus.values.map((status) {
                    return DropdownMenuItem(
                      value: status,
                      child: Row(
                        children: [
                          Icon(_getStatusIcon(status),
                              size: 16, color: _getStatusColor(status)),
                          const SizedBox(width: 8),
                          Text(status.displayName),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() => _selectedStatus = value!);
                  },
                ),
                const SizedBox(height: 16),

                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            color: Colors.blue.shade700, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Changing the position will automatically adjust other distributors\' positions to avoid conflicts.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue.shade700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Payroll ─────────────────────────────────────────────────
                _buildPayrollSection(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _uploading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _uploading
              ? null
              : () async {
                  if (!_formKey.currentState!.validate()) return;

                  setState(() => _uploading = true);

                  String? finalImageUrl = widget.distributor.imageUrl;

                  // Upload new image if one was picked
                  if (_pendingImageBytes != null) {
                    try {
                      finalImageUrl = await _uploadImage(widget.distributor.id);
                    } catch (e) {
                      setState(() => _uploading = false);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('Image upload failed: $e'),
                              backgroundColor: Colors.red),
                        );
                      }
                      return;
                    }
                  }

                  final updatedDistributor = widget.distributor.copyWith(
                    name: _nameController.text.trim(),
                    index: int.parse(_indexController.text),
                    phone1: _phone1Controller.text.trim().isEmpty
                        ? null
                        : _phone1Controller.text.trim(),
                    phone2: _phone2Controller.text.trim().isEmpty
                        ? null
                        : _phone2Controller.text.trim(),
                    status: _selectedStatus,
                    role: _selectedRole,
                    imageUrl: finalImageUrl,
                    payroll: _buildPayrollProfile(),
                  );

                  if (mounted) {
                    Navigator.of(context).pop({
                      'distributor': updatedDistributor,
                      'oldIndex': widget.distributor.index,
                    });
                  }
                },
          child: _uploading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save Changes'),
        ),
      ],
    );
  }
}
