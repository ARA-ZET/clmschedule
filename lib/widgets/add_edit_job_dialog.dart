import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/job_list_item.dart';

class AddEditJobDialog extends StatefulWidget {
  final JobListItem? jobToEdit;

  const AddEditJobDialog({super.key, this.jobToEdit});

  @override
  State<AddEditJobDialog> createState() => _AddEditJobDialogState();
}

class _AddEditJobDialogState extends State<AddEditJobDialog> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();

  // Controllers for text fields
  late final TextEditingController _invoiceController;
  late final TextEditingController _amountController;
  late final TextEditingController _clientController;
  late final TextEditingController _areaController;
  late final TextEditingController _quantityController;
  late final TextEditingController _manDaysController;
  late final TextEditingController _collectionAddressController;
  late final TextEditingController _specialInstructionsController;
  late final TextEditingController _quantityDistributedController;
  late final TextEditingController _invoiceDetailsController;
  late final TextEditingController _reportAddressesController;
  late final TextEditingController _whoToInvoiceController;

  // Dropdown values
  late JobListStatus _selectedJobStatus;
  late JobType _selectedJobType;

  // Date values
  late DateTime _selectedDate;
  late DateTime _selectedCollectionDate;

  @override
  void initState() {
    super.initState();

    final job = widget.jobToEdit;

    // Initialize controllers with existing values or empty
    _invoiceController = TextEditingController(text: job?.invoice ?? '');
    _amountController =
        TextEditingController(text: job?.amount.toStringAsFixed(2) ?? '0.00');
    _clientController = TextEditingController(text: job?.client ?? '');
    _areaController = TextEditingController(text: job?.area ?? '');
    _quantityController =
        TextEditingController(text: job?.quantity.toString() ?? '0');
    _manDaysController =
        TextEditingController(text: job?.manDays.toStringAsFixed(1) ?? '0.0');
    _collectionAddressController =
        TextEditingController(text: job?.collectionAddress ?? '');
    _specialInstructionsController =
        TextEditingController(text: job?.specialInstructions ?? '');
    _quantityDistributedController =
        TextEditingController(text: job?.quantityDistributed.toString() ?? '0');
    _invoiceDetailsController =
        TextEditingController(text: job?.invoiceDetails ?? '');
    _reportAddressesController =
        TextEditingController(text: job?.reportAddresses ?? '');
    _whoToInvoiceController =
        TextEditingController(text: job?.whoToInvoice ?? '');

    // Initialize dropdown values
    _selectedJobStatus = job?.jobStatus ?? JobListStatus.standby;
    _selectedJobType = job?.jobType ?? JobType.flyersPrintingOnly;

    // Initialize dates
    _selectedDate = job?.date ?? DateTime.now();
    _selectedCollectionDate = job?.collectionDate ?? DateTime.now();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _invoiceController.dispose();
    _amountController.dispose();
    _clientController.dispose();
    _areaController.dispose();
    _quantityController.dispose();
    _manDaysController.dispose();
    _collectionAddressController.dispose();
    _specialInstructionsController.dispose();
    _quantityDistributedController.dispose();
    _invoiceDetailsController.dispose();
    _reportAddressesController.dispose();
    _whoToInvoiceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.jobToEdit != null;

    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.9,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isEditing ? 'Edit Job' : 'Add New Job',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Form
            Expanded(
              child: Form(
                key: _formKey,
                child: Scrollbar(
                  controller: _scrollController,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: Column(
                      children: [
                        // Row 1: Invoice, Amount, Client
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _invoiceController,
                                decoration: const InputDecoration(
                                  labelText: 'Invoice *',
                                  border: OutlineInputBorder(),
                                ),
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Invoice is required';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextFormField(
                                controller: _amountController,
                                decoration: const InputDecoration(
                                  labelText: 'Amount *',
                                  border: OutlineInputBorder(),
                                  prefixText: 'R ',
                                ),
                                keyboardType: const TextInputType.numberWithOptions(
                                    decimal: true),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                      RegExp(r'^\d+\.?\d{0,2}')),
                                ],
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Amount is required';
                                  }
                                  if (double.tryParse(value) == null) {
                                    return 'Please enter a valid amount';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: _clientController,
                                decoration: const InputDecoration(
                                  labelText: 'Client *',
                                  border: OutlineInputBorder(),
                                ),
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Client is required';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Row 2: Job Status, Job Type
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<JobListStatus>(
                                initialValue: _selectedJobStatus,
                                decoration: const InputDecoration(
                                  labelText: 'Job Status *',
                                  border: OutlineInputBorder(),
                                ),
                                items: JobListStatus.values.map((status) {
                                  return DropdownMenuItem<JobListStatus>(
                                    value: status,
                                    child: Text(status.displayName),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() {
                                      _selectedJobStatus = value;
                                    });
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: DropdownButtonFormField<JobType>(
                                initialValue: _selectedJobType,
                                decoration: const InputDecoration(
                                  labelText: 'Job Type *',
                                  border: OutlineInputBorder(),
                                ),
                                items: JobType.values.map((type) {
                                  return DropdownMenuItem<JobType>(
                                    value: type,
                                    child: Text(type.displayName),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() {
                                      _selectedJobType = value;
                                    });
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Row 3: Area, Quantity
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: _areaController,
                                decoration: const InputDecoration(
                                  labelText: 'Area',
                                  border: OutlineInputBorder(),
                                ),
                                maxLines: 2,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextFormField(
                                controller: _quantityController,
                                decoration: const InputDecoration(
                                  labelText: 'Quantity',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Man-Days field
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _manDaysController,
                                decoration: const InputDecoration(
                                  labelText: 'Man-Days',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'^\d+\.?\d{0,2}'),
                                  )
                                ],
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Please enter man-days';
                                  }
                                  if (double.tryParse(value) == null) {
                                    return 'Please enter a valid number';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            const Expanded(child: SizedBox()), // Empty space for alignment
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Row 4: Date, Collection Date
                        Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: () async {
                                  final date = await showDatePicker(
                                    context: context,
                                    initialDate: _selectedDate,
                                    firstDate: DateTime(2020),
                                    lastDate: DateTime(2030),
                                  );
                                  if (date != null) {
                                    setState(() {
                                      _selectedDate = date;
                                    });
                                  }
                                },
                                child: InputDecorator(
                                  decoration: const InputDecoration(
                                    labelText: 'Date',
                                    border: OutlineInputBorder(),
                                    suffixIcon: Icon(Icons.calendar_today),
                                  ),
                                  child: Text(DateFormat('dd MMM yyyy')
                                      .format(_selectedDate)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: InkWell(
                                onTap: () async {
                                  final date = await showDatePicker(
                                    context: context,
                                    initialDate: _selectedCollectionDate,
                                    firstDate: DateTime(2020),
                                    lastDate: DateTime(2030),
                                  );
                                  if (date != null) {
                                    setState(() {
                                      _selectedCollectionDate = date;
                                    });
                                  }
                                },
                                child: InputDecorator(
                                  decoration: const InputDecoration(
                                    labelText: 'Collection Date',
                                    border: OutlineInputBorder(),
                                    suffixIcon: Icon(Icons.calendar_today),
                                  ),
                                  child: Text(DateFormat('dd MMM yyyy')
                                      .format(_selectedCollectionDate)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Row 5: Collection Address
                        TextFormField(
                          controller: _collectionAddressController,
                          decoration: const InputDecoration(
                            labelText: 'Collection Address',
                            border: OutlineInputBorder(),
                          ),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 16),

                        // Row 6: Special Instructions
                        TextFormField(
                          controller: _specialInstructionsController,
                          decoration: const InputDecoration(
                            labelText: 'Special Instructions',
                            border: OutlineInputBorder(),
                          ),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 16),

                        // Row 7: Quantity Distributed
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _quantityDistributedController,
                                decoration: const InputDecoration(
                                  labelText: 'Quantity Distributed',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            const Expanded(child: SizedBox.shrink()), // Spacer
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Row 8: Invoice Details
                        TextFormField(
                          controller: _invoiceDetailsController,
                          decoration: const InputDecoration(
                            labelText: 'Invoice Details',
                            border: OutlineInputBorder(),
                          ),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 16),

                        // Row 9: Report Addresses
                        TextFormField(
                          controller: _reportAddressesController,
                          decoration: const InputDecoration(
                            labelText: 'Report Addresses',
                            border: OutlineInputBorder(),
                          ),
                          maxLines: 3,
                        ),
                        const SizedBox(height: 16),

                        // Row 10: Who to Invoice
                        TextFormField(
                          controller: _whoToInvoiceController,
                          decoration: const InputDecoration(
                            labelText: 'Who to Invoice',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _saveJob,
                  child: Text(isEditing ? 'Update Job' : 'Add Job'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _saveJob() {
    if (_formKey.currentState!.validate()) {
      final jobListItem = JobListItem(
        id: widget.jobToEdit?.id ?? '',
        invoice: _invoiceController.text.trim(),
        amount: double.tryParse(_amountController.text) ?? 0.0,
        client: _clientController.text.trim(),
        jobStatus: _selectedJobStatus,
        jobType: _selectedJobType,
        area: _areaController.text.trim(),
        quantity: int.tryParse(_quantityController.text) ?? 0,
        manDays: double.tryParse(_manDaysController.text) ?? 0.0,
        date: _selectedDate,
        collectionAddress: _collectionAddressController.text.trim(),
        collectionDate: _selectedCollectionDate,
        specialInstructions: _specialInstructionsController.text.trim(),
        quantityDistributed:
            int.tryParse(_quantityDistributedController.text) ?? 0,
        invoiceDetails: _invoiceDetailsController.text.trim(),
        reportAddresses: _reportAddressesController.text.trim(),
        whoToInvoice: _whoToInvoiceController.text.trim(),
      );

      Navigator.of(context).pop(jobListItem);
    }
  }
}
