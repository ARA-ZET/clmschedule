import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/job_list_item.dart';
import '../providers/schedule_provider.dart';
import '../services/job_assignment_service.dart';
import 'job_assignment_preview_dialog.dart';

class AddEditJobDialog extends StatefulWidget {
  final JobListItem? jobToEdit;

  const AddEditJobDialog({super.key, this.jobToEdit});

  @override
  State<AddEditJobDialog> createState() => _AddEditJobDialogState();
}

class _AddEditJobDialogState extends State<AddEditJobDialog> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();

  // Loading state
  bool _isProcessing = false;

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
  String? _selectedVehicleTrailerCombo;

  // Date values
  DateTime? _selectedDate;
  DateTime? _selectedCollectionDate;

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

    // Initialize vehicle/trailer combo based on existing quantity for junk collection
    if ((_selectedJobType == JobType.junkCollection) && job != null) {
      _selectedVehicleTrailerCombo =
          _getVehicleTrailerComboFromQuantity(job.quantity);
    }
    // Initialize vehicle/trailer combo based on existing quantity for junk collection
    if ((_selectedJobType == JobType.furnitureMove) && job != null) {
      _selectedVehicleTrailerCombo =
          _getVehicleTrailerComboFromQuantity(job.quantity);
    }

    // Initialize dates - null for new jobs, existing values for editing
    _selectedDate = job?.date;
    _selectedCollectionDate = job?.collectionDate;
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
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 768;

    return Dialog(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SafeArea(
            child: Container(
              width: isMobile
                  ? MediaQuery.of(context).size.width * 0.95
                  : MediaQuery.of(context).size.width * 0.8,
              height: isMobile
                  ? MediaQuery.of(context).size.height * 0.95
                  : MediaQuery.of(context).size.height * 0.85,
              constraints: BoxConstraints(
                maxWidth:
                    isMobile ? MediaQuery.of(context).size.width * 0.95 : 900,
                maxHeight:
                    isMobile ? MediaQuery.of(context).size.height * 0.95 : 700,
                minWidth: 300,
                minHeight: 400,
              ),
              padding: EdgeInsets.all(isMobile ? 16 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          isEditing ? 'Edit Job' : 'Add New Job',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                          overflow: TextOverflow.ellipsis,
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
                          clipBehavior: Clip.hardEdge,
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            children: [
                              // Row 1: Invoice, Amount, Client - Responsive Layout
                              isMobile
                                  ? Column(
                                      children: [
                                        TextFormField(
                                          controller: _invoiceController,
                                          decoration: const InputDecoration(
                                            labelText: 'Invoice',
                                            border: OutlineInputBorder(),
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        TextFormField(
                                          controller: _amountController,
                                          decoration: const InputDecoration(
                                            labelText: 'Amount *',
                                            border: OutlineInputBorder(),
                                            prefixText: 'R ',
                                          ),
                                          keyboardType: const TextInputType
                                              .numberWithOptions(decimal: true),
                                          inputFormatters: [
                                            FilteringTextInputFormatter.allow(
                                                RegExp(r'^\d+\.?\d{0,2}')),
                                          ],
                                          validator: (value) {
                                            if (value == null ||
                                                value.isEmpty) {
                                              return 'Amount is required';
                                            }
                                            if (double.tryParse(value) ==
                                                null) {
                                              return 'Please enter a valid amount';
                                            }
                                            return null;
                                          },
                                        ),
                                        const SizedBox(height: 12),
                                        TextFormField(
                                          controller: _clientController,
                                          decoration: const InputDecoration(
                                            labelText: 'Client *',
                                            border: OutlineInputBorder(),
                                          ),
                                          validator: (value) {
                                            if (value == null ||
                                                value.isEmpty) {
                                              return 'Client is required';
                                            }
                                            return null;
                                          },
                                        ),
                                      ],
                                    )
                                  : Row(
                                      children: [
                                        Expanded(
                                          child: TextFormField(
                                            controller: _invoiceController,
                                            decoration: const InputDecoration(
                                              labelText: 'Invoice',
                                              border: OutlineInputBorder(),
                                            ),
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
                                            keyboardType: const TextInputType
                                                .numberWithOptions(
                                                decimal: true),
                                            inputFormatters: [
                                              FilteringTextInputFormatter.allow(
                                                  RegExp(r'^\d+\.?\d{0,2}')),
                                            ],
                                            validator: (value) {
                                              if (value == null ||
                                                  value.isEmpty) {
                                                return 'Amount is required';
                                              }
                                              if (double.tryParse(value) ==
                                                  null) {
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
                                              if (value == null ||
                                                  value.isEmpty) {
                                                return 'Client is required';
                                              }
                                              return null;
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                              const SizedBox(height: 16),

                              // Row 2: Job Status, Job Type - Responsive Layout
                              isMobile
                                  ? Column(
                                      children: [
                                        TextFormField(
                                          controller: _areaController,
                                          decoration: const InputDecoration(
                                            labelText: 'Area',
                                            border: OutlineInputBorder(),
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        DropdownButtonFormField<JobListStatus>(
                                          initialValue: _selectedJobStatus,
                                          decoration: const InputDecoration(
                                            labelText: 'Job Status *',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: JobListStatus.values
                                              .map((status) {
                                            return DropdownMenuItem<
                                                JobListStatus>(
                                              value: status,
                                              child: Text(
                                                status.displayName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
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
                                        const SizedBox(height: 12),
                                        DropdownButtonFormField<JobType>(
                                          initialValue: _selectedJobType,
                                          decoration: const InputDecoration(
                                            labelText: 'Job Type *',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: JobType.values.map((type) {
                                            return DropdownMenuItem<JobType>(
                                              value: type,
                                              child: Text(
                                                type.displayName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            );
                                          }).toList(),
                                          onChanged: (value) {
                                            if (value != null) {
                                              setState(() {
                                                _selectedJobType = value;
                                                // Reset vehicle/trailer combo when job type changes
                                                if (value ==
                                                        JobType
                                                            .junkCollection ||
                                                    value ==
                                                        JobType.furnitureMove) {
                                                  _selectedVehicleTrailerCombo =
                                                      null;
                                                  _quantityController.text =
                                                      '1';
                                                } else {
                                                  _selectedVehicleTrailerCombo =
                                                      null;
                                                }
                                              });
                                            }
                                          },
                                        ),
                                      ],
                                    )
                                  : Row(
                                      children: [
                                        Flexible(
                                          child: TextFormField(
                                            controller: _areaController,
                                            decoration: const InputDecoration(
                                              labelText: 'Area',
                                              border: OutlineInputBorder(),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Flexible(
                                          flex: 2,
                                          child: DropdownButtonFormField<
                                              JobListStatus>(
                                            initialValue: _selectedJobStatus,
                                            decoration: const InputDecoration(
                                              labelText: 'Job Status *',
                                              border: OutlineInputBorder(),
                                            ),
                                            items: JobListStatus.values
                                                .map((status) {
                                              return DropdownMenuItem<
                                                  JobListStatus>(
                                                value: status,
                                                child: Text(
                                                  status.displayName,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
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
                                        const SizedBox(width: 12),
                                        Flexible(
                                          flex: 2,
                                          child:
                                              DropdownButtonFormField<JobType>(
                                            initialValue: _selectedJobType,
                                            decoration: const InputDecoration(
                                              labelText: 'Job Type *',
                                              border: OutlineInputBorder(),
                                            ),
                                            items: JobType.values.map((type) {
                                              return DropdownMenuItem<JobType>(
                                                value: type,
                                                child: Text(
                                                  type.displayName,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              );
                                            }).toList(),
                                            onChanged: (value) {
                                              if (value != null) {
                                                setState(() {
                                                  _selectedJobType = value;
                                                  // Reset vehicle/trailer combo when job type changes
                                                  if (value ==
                                                          JobType
                                                              .junkCollection ||
                                                      value ==
                                                          JobType
                                                              .furnitureMove) {
                                                    _selectedVehicleTrailerCombo =
                                                        null;
                                                    _quantityController.text =
                                                        '1';
                                                  } else {
                                                    _selectedVehicleTrailerCombo =
                                                        null;
                                                  }
                                                });
                                              }
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                              const SizedBox(height: 16),

                              // Row 3: Area, Quantity (conditional based on job type)
                              Row(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: (_selectedJobType ==
                                                JobType.junkCollection ||
                                            _selectedJobType ==
                                                JobType.furnitureMove)
                                        ? DropdownButtonFormField<String>(
                                            initialValue:
                                                _selectedVehicleTrailerCombo,
                                            decoration: const InputDecoration(
                                              labelText: 'Vehicle & Trailer',
                                              border: OutlineInputBorder(),
                                            ),
                                            items:
                                                _getVehicleTrailerCombinations()
                                                    .map((combo) {
                                              return DropdownMenuItem<String>(
                                                value: combo,
                                                child: Text(combo),
                                              );
                                            }).toList(),
                                            onChanged: (value) {
                                              setState(() {
                                                _selectedVehicleTrailerCombo =
                                                    value;
                                                // Update quantity controller to reflect the selection
                                                _quantityController.text =
                                                    _getQuantityFromVehicleTrailerCombo(
                                                            value)
                                                        .toString();
                                              });
                                            },
                                            validator: (value) {
                                              if ((_selectedJobType ==
                                                          JobType
                                                              .junkCollection ||
                                                      _selectedJobType ==
                                                          JobType
                                                              .furnitureMove) &&
                                                  value == null) {
                                                return 'Please select vehicle & trailer';
                                              }
                                              return null;
                                            },
                                          )
                                        : TextFormField(
                                            controller: _quantityController,
                                            decoration: const InputDecoration(
                                              labelText: 'Quantity / Vehicle',
                                              border: OutlineInputBorder(),
                                            ),
                                            keyboardType: TextInputType.number,
                                            inputFormatters: [
                                              FilteringTextInputFormatter
                                                  .digitsOnly
                                            ],
                                          ),
                                  ),
                                  const SizedBox(width: 16),
                                  // Man-Days field
                                  Expanded(
                                    flex: 1,
                                    child: TextFormField(
                                      controller: _manDaysController,
                                      decoration: const InputDecoration(
                                        labelText: 'Man-Days *',
                                        border: OutlineInputBorder(),
                                      ),
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                              decimal: true),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'^\d+\.?\d{0,2}'),
                                        )
                                      ],
                                      validator: (value) {
                                        if (value == null || value.isEmpty) {
                                          return 'Man-Days is required';
                                        }
                                        final doubleValue =
                                            double.tryParse(value);
                                        if (doubleValue == null) {
                                          return 'Please enter a valid number';
                                        }
                                        if (doubleValue <= 0) {
                                          return 'Man-Days must be greater than 0';
                                        }
                                        return null;
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    flex: 2,
                                    child: FormField<DateTime>(
                                      initialValue: _selectedDate,
                                      validator: (value) {
                                        if (value == null) {
                                          return 'Distribution Date is required';
                                        }
                                        return null;
                                      },
                                      builder:
                                          (FormFieldState<DateTime> state) {
                                        return InkWell(
                                          onTap: () async {
                                            final date = await showDatePicker(
                                              context: context,
                                              initialDate: _selectedDate ??
                                                  DateTime.now(),
                                              firstDate: DateTime(2020),
                                              lastDate: DateTime(2030),
                                            );
                                            if (date != null) {
                                              DateTime finalDate = date;

                                              // If this job type needs time selection, show time picker
                                              if (_needsTimeSelection(
                                                  _selectedJobType)) {
                                                if (!mounted) return;
                                                final timeSlots =
                                                    _getAvailableTimeSlots();
                                                final selectedTime =
                                                    await showDialog<TimeOfDay>(
                                                  context: context,
                                                  builder: (context) =>
                                                      AlertDialog(
                                                    title: const Text(
                                                        'Select Time'),
                                                    content: SizedBox(
                                                      width: 300,
                                                      height: 400,
                                                      child: ListView.builder(
                                                        itemCount:
                                                            timeSlots.length,
                                                        itemBuilder:
                                                            (context, index) {
                                                          final time =
                                                              timeSlots[index];
                                                          return ListTile(
                                                            title: Text(
                                                                _formatTimeOfDay(
                                                                    time)),
                                                            onTap: () =>
                                                                Navigator.of(
                                                                        context)
                                                                    .pop(time),
                                                          );
                                                        },
                                                      ),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.of(
                                                                    context)
                                                                .pop(),
                                                        child: const Text(
                                                            'Cancel'),
                                                      ),
                                                    ],
                                                  ),
                                                );

                                                if (selectedTime != null) {
                                                  finalDate = DateTime(
                                                    date.year,
                                                    date.month,
                                                    date.day,
                                                    selectedTime.hour,
                                                    selectedTime.minute,
                                                  );
                                                } else {
                                                  return; // User cancelled time selection
                                                }
                                              }

                                              setState(() {
                                                _selectedDate = finalDate;
                                              });
                                              state.didChange(finalDate);
                                            }
                                          },
                                          child: InputDecorator(
                                            decoration: InputDecoration(
                                              labelText: _needsTimeSelection(
                                                      _selectedJobType)
                                                  ? 'Appointment Date & Time *'
                                                  : 'Distribution Date *',
                                              border:
                                                  const OutlineInputBorder(),
                                              suffixIcon: Icon(
                                                  _needsTimeSelection(
                                                          _selectedJobType)
                                                      ? Icons.schedule
                                                      : Icons.calendar_today),
                                              errorText: state.errorText,
                                            ),
                                            child: Text(_selectedDate != null
                                                ? _needsTimeSelection(
                                                        _selectedJobType)
                                                    ? DateFormat(
                                                            'dd MMM, HH:mm')
                                                        .format(_selectedDate!)
                                                    : DateFormat('dd MMM yyyy')
                                                        .format(_selectedDate!)
                                                : _needsTimeSelection(
                                                        _selectedJobType)
                                                    ? 'Select Date & Time'
                                                    : 'Select Distribution Date'),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    flex: 2,
                                    child: FormField<DateTime>(
                                      initialValue: _selectedCollectionDate,
                                      validator: (value) {
                                        // Collection Date is not required
                                        return null;
                                      },
                                      builder:
                                          (FormFieldState<DateTime> state) {
                                        return InkWell(
                                          onTap: () async {
                                            final date = await showDatePicker(
                                              context: context,
                                              initialDate:
                                                  _selectedCollectionDate ??
                                                      DateTime.now(),
                                              firstDate: DateTime(2020),
                                              lastDate: DateTime(2030),
                                            );
                                            if (date != null) {
                                              setState(() {
                                                _selectedCollectionDate = date;
                                              });
                                              state.didChange(date);
                                            }
                                          },
                                          child: InputDecorator(
                                            decoration: InputDecoration(
                                              labelText: 'Collection Date',
                                              border:
                                                  const OutlineInputBorder(),
                                              suffixIcon: const Icon(
                                                  Icons.calendar_today),
                                              errorText: state.errorText,
                                            ),
                                            child: Text(_selectedCollectionDate !=
                                                    null
                                                ? DateFormat('dd MMM yyyy')
                                                    .format(
                                                        _selectedCollectionDate!)
                                                : 'Select Collection Date'),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              // Row 5: Collection Address
                              Row(children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _collectionAddressController,
                                    decoration: const InputDecoration(
                                      labelText: 'Collection Address',
                                      border: OutlineInputBorder(),
                                    ),
                                    maxLines: 2,
                                  ),
                                ),
                                const SizedBox(width: 16),

                                // Row 6: Special Instructions
                                Expanded(
                                  child: TextFormField(
                                    controller: _specialInstructionsController,
                                    decoration: const InputDecoration(
                                      labelText: 'Special Instructions',
                                      border: OutlineInputBorder(),
                                    ),
                                    maxLines: 2,
                                  ),
                                ),
                              ]),
                              const SizedBox(height: 16),
                              // Row 7: Quantity Distributed
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller:
                                          _quantityDistributedController,
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
                                  Expanded(
                                    child: TextFormField(
                                      controller: _invoiceDetailsController,
                                      decoration: const InputDecoration(
                                        labelText: 'Invoice Details',
                                        border: OutlineInputBorder(),
                                      ),
                                      maxLines: 1,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),

                              // Row 8: Invoice Details, Report Addresses, Who to Invoice
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller: _reportAddressesController,
                                      decoration: const InputDecoration(
                                        labelText: 'Report Addresses',
                                        border: OutlineInputBorder(),
                                      ),
                                      maxLines: 1,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: TextFormField(
                                      controller: _whoToInvoiceController,
                                      decoration: const InputDecoration(
                                        labelText: 'Who to Invoice',
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Action buttons
                  isMobile
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!isEditing) // Only show skip allocation for new jobs
                              ElevatedButton(
                                onPressed: _isProcessing
                                    ? null
                                    : _saveJobWithoutAllocation,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      const Color.fromARGB(255, 247, 224, 189),
                                  foregroundColor: Colors.white,
                                ),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      )
                                    : const Text('Skip Allocation'),
                              ),
                            if (!isEditing) const SizedBox(height: 8),
                            if (isEditing) // Show automatic allocation for editing
                              ElevatedButton(
                                onPressed: _isProcessing
                                    ? null
                                    : _saveJobWithAutomaticAllocation,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                  foregroundColor: Colors.white,
                                ),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      )
                                    : const Text('Automatic Allocation'),
                              ),
                            if (isEditing) const SizedBox(height: 8),
                            ElevatedButton(
                              onPressed: _isProcessing ? null : _saveJob,
                              child: _isProcessing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                Colors.green),
                                      ),
                                    )
                                  : Text(isEditing ? 'Update Job' : 'Add Job'),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: _isProcessing
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              child: const Text('Cancel'),
                            ),
                          ],
                        )
                      : Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TextButton(
                              onPressed: _isProcessing
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              child: const Text('Cancel'),
                            ),
                            if (!isEditing) // Only show skip allocation for new jobs
                              ElevatedButton(
                                onPressed: _isProcessing
                                    ? null
                                    : _saveJobWithoutAllocation,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      const Color.fromARGB(255, 248, 225, 191),
                                  foregroundColor: Colors.black,
                                ),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      )
                                    : const Text('Skip Allocation'),
                              ),
                            if (isEditing) // Show automatic allocation for editing
                              ElevatedButton(
                                onPressed: _isProcessing
                                    ? null
                                    : _saveJobWithAutomaticAllocation,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                  foregroundColor: Colors.white,
                                ),
                                child: _isProcessing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  Colors.white),
                                        ),
                                      )
                                    : const Text('Automatic Allocation'),
                              ),
                            ElevatedButton(
                              onPressed: _isProcessing ? null : _saveJob,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                              child: _isProcessing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                Colors.white),
                                      ),
                                    )
                                  : Text(isEditing ? 'Update Job' : 'Add Job'),
                            ),
                          ],
                        ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _saveJob() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isProcessing = true;
      });

      final jobListItem = JobListItem(
        id: widget.jobToEdit?.id ?? '',
        invoice: _invoiceController.text.trim(),
        amount: double.tryParse(_amountController.text) ?? 0.0,
        client: _clientController.text.trim(),
        jobStatusId: _selectedJobStatus.customStatusId,
        jobType: _selectedJobType,
        area: _areaController.text.trim(),
        quantity: int.tryParse(_quantityController.text) ?? 0,
        manDays: double.tryParse(_manDaysController.text) ?? 0.0,
        date: _selectedDate ?? DateTime.now(),
        collectionAddress: _collectionAddressController.text.trim(),
        collectionDate: _selectedCollectionDate ?? DateTime.now(),
        specialInstructions: _specialInstructionsController.text.trim(),
        quantityDistributed:
            int.tryParse(_quantityDistributedController.text) ?? 0,
        invoiceDetails: _invoiceDetailsController.text.trim(),
        reportAddresses: _reportAddressesController.text.trim(),
        whoToInvoice: _whoToInvoiceController.text.trim(),
      );

      try {
        // If editing existing job
        if (widget.jobToEdit != null) {
          // Check if this is a collection job and if time/date changed
          if ((_selectedJobType == JobType.junkCollection ||
                  _selectedJobType == JobType.furnitureMove) &&
              widget.jobToEdit!.collectionJobId.isNotEmpty) {
            // Update the linked collection job if date/time changed
            // Collection job updates are now automatic via JobListProvider stream
          }
          Navigator.of(context).pop(jobListItem);
          return;
        }

        // For new jobs, check if this is a collection job type
        if (_selectedJobType == JobType.junkCollection ||
            _selectedJobType == JobType.furnitureMove) {
          // Collection jobs are automatically derived from job list data
          // Just save the job and it will appear in collection schedule
          if (mounted) {
            Navigator.of(context).pop(jobListItem);
          }
          return;
        } else {
          // For other job types, show regular assignment preview
          await _showJobAssignmentPreview(jobListItem);
        }
      } finally {
        if (mounted) {
          setState(() {
            _isProcessing = false;
          });
        }
      }
    }
  }

  void _saveJobWithoutAllocation() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isProcessing = true;
      });

      final jobListItem = JobListItem(
        id: widget.jobToEdit?.id ?? '',
        invoice: _invoiceController.text.trim(),
        amount: double.tryParse(_amountController.text) ?? 0.0,
        client: _clientController.text.trim(),
        jobStatusId: _selectedJobStatus.customStatusId,
        jobType: _selectedJobType,
        area: _areaController.text.trim(),
        quantity: int.tryParse(_quantityController.text) ?? 0,
        manDays: double.tryParse(_manDaysController.text) ?? 0.0,
        date: _selectedDate ?? DateTime.now(),
        collectionAddress: _collectionAddressController.text.trim(),
        collectionDate: _selectedCollectionDate ?? DateTime.now(),
        specialInstructions: _specialInstructionsController.text.trim(),
        quantityDistributed:
            int.tryParse(_quantityDistributedController.text) ?? 0,
        invoiceDetails: _invoiceDetailsController.text.trim(),
        reportAddresses: _reportAddressesController.text.trim(),
        whoToInvoice: _whoToInvoiceController.text.trim(),
      );

      try {
        // Return job with a special flag to indicate skip allocation
        Navigator.of(context).pop({'job': jobListItem, 'skipAllocation': true});
      } finally {
        if (mounted) {
          setState(() {
            _isProcessing = false;
          });
        }
      }
    }
  }

  void _saveJobWithAutomaticAllocation() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isProcessing = true;
      });

      final jobListItem = JobListItem(
        id: widget.jobToEdit?.id ?? '',
        invoice: _invoiceController.text.trim(),
        amount: double.tryParse(_amountController.text) ?? 0.0,
        client: _clientController.text.trim(),
        jobStatusId: _selectedJobStatus.customStatusId,
        jobType: _selectedJobType,
        area: _areaController.text.trim(),
        quantity: int.tryParse(_quantityController.text) ?? 0,
        manDays: double.tryParse(_manDaysController.text) ?? 0.0,
        date: _selectedDate ?? DateTime.now(),
        collectionAddress: _collectionAddressController.text.trim(),
        collectionDate: _selectedCollectionDate ?? DateTime.now(),
        specialInstructions: _specialInstructionsController.text.trim(),
        quantityDistributed:
            int.tryParse(_quantityDistributedController.text) ?? 0,
        invoiceDetails: _invoiceDetailsController.text.trim(),
        reportAddresses: _reportAddressesController.text.trim(),
        whoToInvoice: _whoToInvoiceController.text.trim(),
      );

      try {
        // For editing with automatic allocation, show assignment preview
        await _showJobAssignmentPreview(jobListItem);
      } finally {
        if (mounted) {
          setState(() {
            _isProcessing = false;
          });
        }
      }
    }
  }

  Future<void> _showJobAssignmentPreview(JobListItem jobListItem) async {
    try {
      // Get the schedule provider
      final scheduleProvider = context.read<ScheduleProvider>();

      // Create the assignment service
      final assignmentService = JobAssignmentService(scheduleProvider);

      // Calculate the job assignments
      final assignments = assignmentService.calculateJobAssignments(
        client: jobListItem.client,
        manDays: jobListItem.manDays,
        startDate: jobListItem.date,
        workingArea: '.', // Default - can be edited later on schedule
      );

      if (assignments.isEmpty) {
        // Show error if no assignments could be made
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Unable to assign jobs - no available distributors found.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Show the assignment preview dialog
      if (mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => JobAssignmentPreviewDialog(
            assignments: assignments,
            onConfirm: () => Navigator.of(context).pop(true),
            onCancel: () => Navigator.of(context).pop(false),
          ),
        );

        if (confirmed == true && mounted) {
          // User confirmed - create the jobs on the schedule
          await _createScheduleJobs(assignmentService, assignments);

          // Return the original job list item
          if (mounted) {
            Navigator.of(context).pop(jobListItem);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating job assignments: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _createScheduleJobs(JobAssignmentService assignmentService,
      List<JobAssignment> assignments) async {
    try {
      final scheduleProvider = context.read<ScheduleProvider>();

      // Convert assignments to Job objects
      final jobs = assignmentService.createJobsFromAssignments(assignments);

      // Add each job to the schedule
      for (final job in jobs) {
        await scheduleProvider.addJob(job);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Successfully assigned ${jobs.length} jobs to distributors!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding jobs to schedule: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      rethrow; // Re-throw so the calling method can handle it
    }
  }

  // Helper methods for vehicle/trailer combinations
  List<String> _getVehicleTrailerCombinations() {
    return [
      'Hyundai - No Trailer',
      'Hyundai - Big Trailer',
      'Hyundai - Small Trailer',
      'Mahindra - No Trailer',
      'Mahindra - Big Trailer',
      'Mahindra - Small Trailer',
      'Nissan - No Trailer',
      'Nissan - Big Trailer',
      'Nissan - Small Trailer',
    ];
  }

  String? _getVehicleTrailerComboFromQuantity(int quantity) {
    final combinations = _getVehicleTrailerCombinations();
    if (quantity >= 1 && quantity <= combinations.length) {
      return combinations[quantity - 1];
    }
    return null;
  }

  int _getQuantityFromVehicleTrailerCombo(String? combo) {
    if (combo == null) return 1;
    final combinations = _getVehicleTrailerCombinations();
    final index = combinations.indexOf(combo);
    return index >= 0 ? index + 1 : 1;
  }

  // Helper methods for time selection
  bool _needsTimeSelection(JobType jobType) {
    return jobType == JobType.junkCollection ||
        jobType == JobType.furnitureMove ||
        jobType == JobType.windowCleaning ||
        jobType == JobType.solarPanelCleaning;
  }

  List<TimeOfDay> _getAvailableTimeSlots() {
    final slots = <TimeOfDay>[];
    // Generate 30-minute intervals from 08:00 AM to 16:00 PM (4:00 PM)
    for (int hour = 8; hour <= 16; hour++) {
      slots.add(TimeOfDay(hour: hour, minute: 0));
      if (hour < 16) {
        slots.add(TimeOfDay(hour: hour, minute: 30));
      }
    }
    return slots;
  }

  String _formatTimeOfDay(TimeOfDay time) {
    final now = DateTime.now();
    final dateTime =
        DateTime(now.year, now.month, now.day, time.hour, time.minute);
    return DateFormat('HH:mm').format(dateTime);
  }
}
