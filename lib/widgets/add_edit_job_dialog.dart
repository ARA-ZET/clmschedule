import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/job_list_item.dart';
import '../models/job_list_item_update.dart';
import '../models/collection_job.dart';
import '../models/custom_job_list_status.dart';
import '../models/custom_job_type.dart';
import '../models/custom_polygon.dart';
import '../models/happy_sun_shared.dart';
import '../providers/auth_provider.dart';
import '../providers/job_list_provider.dart';
import '../providers/job_list_status_provider.dart';
import '../providers/schedule_provider.dart';
import '../providers/collection_schedule_provider.dart';
import '../providers/inventory_provider.dart';
import '../providers/tool_settings_provider.dart';
import '../providers/job_type_provider.dart';
import '../services/job_assignment_service.dart';
import '../shareable_maps/services/map_link_service.dart';
import 'address_point_search_dialog.dart';
import 'job_assignment_preview_dialog.dart';
import 'happy_sun_tools_dialog.dart';

class AddEditJobDialog extends riverpod.ConsumerStatefulWidget {
  final JobListItem? jobToEdit;

  /// When true, shows a read-only "Map will be copied" notice in the Area
  /// field to indicate that the linked map from the source job will be
  /// cloned after the copy is saved.
  final bool mapWillBeCopied;

  const AddEditJobDialog({
    super.key,
    this.jobToEdit,
    this.mapWillBeCopied = false,
  });

  @override
  riverpod.ConsumerState<AddEditJobDialog> createState() =>
      _AddEditJobDialogState();
}

class _AddEditJobDialogState extends riverpod.ConsumerState<AddEditJobDialog> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();

  // Loading state
  bool _isProcessing = false;

  // Shareable map suggestions for the Area field (name → share URL)
  List<_MapSuggestion> _mapSuggestions = [];

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
  late String _selectedJobStatusId; // Now stores custom status ID
  late String _selectedJobType;
  VehicleTrailerCombo? _selectedVehicleTrailerCombo;

  // Date values
  DateTime? _selectedDate;
  DateTime? _selectedCollectionDate;

  // Tools needed for Happy Sun jobs (window/solar cleaning)
  CategorizedTools? _toolsNeeded;

  @override
  void initState() {
    super.initState();

    final job = widget.jobToEdit;
    debugPrint('\n📋 AddEditJobDialog: Opening dialog');
    debugPrint('   Mode: ${job != null ? "EDIT" : "CREATE"}');
    if (job != null) {
      debugPrint('   Job ID: ${job.id}');
      debugPrint('   Job Type: ${job.jobTypeId}');
      debugPrint('   Client: ${job.client}');
    }

    // Initialize controllers with existing values or empty
    _invoiceController = TextEditingController(text: job?.invoice ?? '');
    _amountController =
        TextEditingController(text: job?.amount.toStringAsFixed(2) ?? '');
    _clientController = TextEditingController(text: job?.client ?? '');
    _areaController = TextEditingController(text: job?.area ?? '');
    _quantityController =
        TextEditingController(text: job?.quantity.toString() ?? '');
    _manDaysController =
        TextEditingController(text: job?.manDays.toStringAsFixed(1) ?? '');
    _collectionAddressController =
        TextEditingController(text: job?.collectionAddress ?? '');
    _specialInstructionsController =
        TextEditingController(text: job?.specialInstructions ?? '');
    _quantityDistributedController =
        TextEditingController(text: job?.quantityDistributed.toString() ?? '');
    _invoiceDetailsController =
        TextEditingController(text: job?.invoiceDetails ?? '');
    _reportAddressesController =
        TextEditingController(text: job?.reportAddresses ?? '');
    _whoToInvoiceController =
        TextEditingController(text: job?.whoToInvoice ?? '');

    // Initialize dropdown values
    _selectedJobStatusId = job?.jobStatusId ?? 'standby';
    _selectedJobType = job?.jobTypeId ?? 'flyersPrintingOnly';

    // Initialize vehicle/trailer combo from existing job
    if (VehicleTrailerCombo.isVehicleJobType(_selectedJobType) && job != null) {
      _selectedVehicleTrailerCombo =
          VehicleTrailerCombo.tryParse(job.vehicleTrailerCombo) ??
              VehicleTrailerCombo.fromLegacyQuantity(job.quantity,
                  jobTypeId: _selectedJobType);
      // Ensure the combo is valid for this job type
      final validCombos = VehicleTrailerCombo.forJobType(_selectedJobType);
      if (_selectedVehicleTrailerCombo != null &&
          !validCombos.contains(_selectedVehicleTrailerCombo)) {
        _selectedVehicleTrailerCombo = null;
      }
    }

    // Initialize dates - null for new jobs, existing values for editing
    _selectedDate = job?.date;
    _selectedCollectionDate = job?.collectionDate;

    // Initialize tools needed for Happy Sun jobs
    _toolsNeeded = job?.toolsNeeded;

    // Fetch shareable map names for area field suggestions
    _loadMapNames();
  }

  Future<void> _loadMapNames() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('mapLinks')
          .orderBy('createdAt', descending: true)
          .get();
      final suggestions = <_MapSuggestion>[];
      final seen = <String>{};
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final name = data['mapName'] as String? ?? '';
        if (name.isEmpty) continue;
        final code = doc.id;
        final url = MapLinkService.buildShareUrl(code);
        // Deduplicate by name
        if (seen.add(name.toLowerCase())) {
          suggestions.add(_MapSuggestion(name: name, url: url));
        }
      }
      suggestions
          .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (mounted) {
        setState(() => _mapSuggestions = suggestions);
      }
    } catch (e) {
      debugPrint('Failed to load map suggestions: $e');
    }
  }

  /// Handles a job type selection change. Extracted so both the compact
  /// and expanded form layouts stay in sync and behave identically.
  void _onJobTypeChanged(String newId) {
    setState(() {
      _selectedJobType = newId;
      // Reset vehicle/trailer combo whenever the type changes. If the new
      // type participates in the Collection Schedule, also reset the
      // quantity placeholder to "1".
      _selectedVehicleTrailerCombo = null;
      if (VehicleTrailerCombo.isVehicleJobType(newId)) {
        _quantityController.text = '1';
      }
    });
  }

  /// Resolves a Material [IconData] for the [CustomJobType.iconName] string.
  /// Kept in sync with the 12-option picker in `JobTypeManagementDialog`.
  IconData _iconDataForJobType(String? name) {
    switch (name) {
      case 'work_outline':
        return Icons.work_outline;
      case 'local_shipping':
        return Icons.local_shipping;
      case 'home_repair_service':
        return Icons.home_repair_service;
      case 'cleaning_services':
        return Icons.cleaning_services;
      case 'solar_power':
        return Icons.solar_power;
      case 'delete_outline':
        return Icons.delete_outline;
      case 'move_to_inbox':
        return Icons.move_to_inbox;
      case 'description':
        return Icons.description;
      case 'article':
        return Icons.article;
      case 'calendar_month':
        return Icons.calendar_month;
      case 'handyman':
        return Icons.handyman;
      case 'build':
        return Icons.build;
      default:
        return Icons.work_outline;
    }
  }

  /// Modern tap-to-open job-type selector. Renders the selected type's
  /// colored avatar + label + chevron in an outlined field; tapping opens
  /// an anchored dropdown menu positioned directly below the field.
  Widget _buildJobTypeField() {
    final provider = ref.watch(jobTypeRiverpod);
    final selected = provider.getJobTypeById(_selectedJobType);
    final accent = selected?.colorValue != null
        ? Color(selected!.colorValue!)
        : Theme.of(context).colorScheme.primary;
    final iconColor =
        accent.computeLuminance() > 0.6 ? Colors.black87 : Colors.white;

    return _PickerFieldShell(
      label: 'Job Type *',
      accent: accent,
      leading: Icon(
        _iconDataForJobType(selected?.iconName),
        size: 14,
        color: iconColor,
      ),
      text: selected?.label ?? 'Select job type',
      isPlaceholder: selected == null,
      onTap: (ctx) => _showJobTypePicker(ctx, provider.jobTypes),
    );
  }

  /// Builds the Job Status picker field matching [_buildJobTypeField]'s style.
  Widget _buildJobStatusField() {
    final statusProvider = ref.watch(jobListStatusRiverpod);
    var statuses = statusProvider.getStatusesForJobType(_selectedJobType);
    // Keep current selection valid even if the status would normally be
    // hidden for the selected job type.
    if (!statuses.any((s) => s.id == _selectedJobStatusId)) {
      final current = statusProvider.getStatusById(_selectedJobStatusId);
      if (current != null) {
        statuses = [current, ...statuses];
      }
    }
    final current = statusProvider.getStatusById(_selectedJobStatusId);
    final accent = current?.color ?? Theme.of(context).colorScheme.primary;

    return _PickerFieldShell(
      label: 'Job Status *',
      accent: accent,
      text: current?.label ?? 'Select status',
      isPlaceholder: current == null,
      onTap: (ctx) => _showJobStatusPicker(ctx, statuses),
    );
  }

  /// Builds the Vehicle & Trailer picker field matching the unified style.
  Widget _buildVehicleTrailerField() {
    final combos = VehicleTrailerCombo.forJobType(_selectedJobType);
    final selected = _selectedVehicleTrailerCombo;
    final accent = Theme.of(context).colorScheme.primary;

    return _PickerFieldShell(
      label: 'Vehicle & Trailer *',
      accent: accent,
      leading: const Icon(Icons.local_shipping, size: 14, color: Colors.white),
      text: selected?.label ?? 'Select vehicle & trailer',
      isPlaceholder: selected == null,
      onTap: (ctx) => _showVehicleTrailerPicker(ctx, combos),
    );
  }

  /// Opens an anchored dropdown menu beneath the tapped field and returns
  /// the selected job type id. Uses [showMenu] for native anchoring.
  Future<void> _showJobTypePicker(
    BuildContext anchorContext,
    List<CustomJobType> jobTypes,
  ) async {
    final picked = await _showAnchoredMenu<String>(
      anchorContext: anchorContext,
      items: jobTypes.map((t) {
        return PopupMenuItem<String>(
          value: t.id,
          padding: EdgeInsets.zero,
          height: 0,
          child: _JobTypeRow(
            type: t,
            icon: _iconDataForJobType(t.iconName),
            selected: t.id == _selectedJobType,
          ),
        );
      }).toList(),
    );
    if (picked != null && picked != _selectedJobType) {
      _onJobTypeChanged(picked);
    }
  }

  Future<void> _showJobStatusPicker(
    BuildContext anchorContext,
    List<CustomJobListStatus> statuses,
  ) async {
    final picked = await _showAnchoredMenu<String>(
      anchorContext: anchorContext,
      items: statuses.map((s) {
        return PopupMenuItem<String>(
          value: s.id,
          padding: EdgeInsets.zero,
          height: 0,
          child: _SimplePickerRow(
            color: s.color,
            label: s.label,
            selected: s.id == _selectedJobStatusId,
          ),
        );
      }).toList(),
    );
    if (picked != null && picked != _selectedJobStatusId) {
      setState(() => _selectedJobStatusId = picked);
    }
  }

  Future<void> _showVehicleTrailerPicker(
    BuildContext anchorContext,
    List<VehicleTrailerCombo> combos,
  ) async {
    final accent = Theme.of(context).colorScheme.primary;
    final picked = await _showAnchoredMenu<VehicleTrailerCombo>(
      anchorContext: anchorContext,
      items: combos.map((c) {
        return PopupMenuItem<VehicleTrailerCombo>(
          value: c,
          padding: EdgeInsets.zero,
          height: 0,
          child: _SimplePickerRow(
            color: accent,
            icon: Icons.local_shipping,
            label: c.label,
            selected: c == _selectedVehicleTrailerCombo,
          ),
        );
      }).toList(),
    );
    if (picked != null && picked != _selectedVehicleTrailerCombo) {
      setState(() {
        _selectedVehicleTrailerCombo = picked;
        _quantityController.text =
            (picked.legacyQuantity(jobTypeId: _selectedJobType)).toString();
      });
    }
  }

  /// Generic anchored menu helper. Computes the field's global rect and
  /// opens [showMenu] just below it, constrained to the field width.
  Future<T?> _showAnchoredMenu<T>({
    required BuildContext anchorContext,
    required List<PopupMenuEntry<T>> items,
    double extraWidth = 40,
    double maxHeight = 420,
  }) async {
    final button = anchorContext.findRenderObject() as RenderBox?;
    final overlay = Navigator.of(anchorContext)
        .overlay
        ?.context
        .findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return null;
    final topLeft = button.localToGlobal(
      Offset(0, button.size.height + 4),
      ancestor: overlay,
    );
    final bottomRight = button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final position = RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      overlay.size.width - bottomRight.dx,
      overlay.size.height - topLeft.dy,
    );
    return showMenu<T>(
      context: anchorContext,
      position: position,
      constraints: BoxConstraints(
        minWidth: button.size.width,
        maxWidth: button.size.width + extraWidth,
        maxHeight: maxHeight,
      ),
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
      ),
      items: items,
    );
  }

  /// Builds an Autocomplete widget for the Area field that suggests
  /// shareable map names as the user types. Selecting a suggestion
  /// inserts the shareable map link URL into the field.
  Widget _buildAreaAutocomplete() {
    // When copying a job that has a linked map, show a read-only hint
    // instead of an empty editable field — the map URL will be filled in
    // automatically once the cloud function finishes cloning the map.
    if (widget.mapWillBeCopied) {
      return InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Area',
          border: OutlineInputBorder(),
        ),
        child: const Text(
          'Map will be copied',
          style: TextStyle(
            color: Colors.blueGrey,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    return Autocomplete<_MapSuggestion>(
      initialValue: TextEditingValue(text: _areaController.text),
      optionsBuilder: (TextEditingValue textEditingValue) {
        if (textEditingValue.text.isEmpty) {
          return const Iterable<_MapSuggestion>.empty();
        }
        final query = textEditingValue.text.toLowerCase();
        return _mapSuggestions
            .where((s) => s.name.toLowerCase().contains(query))
            .take(5);
      },
      displayStringForOption: (_MapSuggestion s) => s.url,
      onSelected: (_MapSuggestion selected) {
        _areaController.text = selected.url;
      },
      fieldViewBuilder: (context, textController, focusNode, onFieldSubmitted) {
        // Sync the autocomplete controller with our _areaController
        // so the form reads the correct value on save.
        textController.addListener(() {
          if (_areaController.text != textController.text) {
            _areaController.text = textController.text;
          }
        });
        return TextFormField(
          controller: textController,
          focusNode: focusNode,
          decoration: const InputDecoration(
            labelText: 'Area',
            border: OutlineInputBorder(),
          ),
          onFieldSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 350),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.map_outlined,
                        size: 18, color: Color(0xFF1967D2)),
                    title:
                        Text(option.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      option.url,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF5F6368)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
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
    final isEditing =
        widget.jobToEdit != null && widget.jobToEdit!.id.isNotEmpty;
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
                        onPressed: _isProcessing
                            ? null
                            : () => Navigator.of(context).pop(),
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
                                            labelText: 'Amount',
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
                                            if (value != null &&
                                                value.isNotEmpty) {
                                              if (double.tryParse(value) ==
                                                  null) {
                                                return 'Please enter a valid amount';
                                              }
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
                                            final trimmed =
                                                value.trim().toLowerCase();
                                            final editingOwn = widget
                                                    .jobToEdit?.client
                                                    .trim()
                                                    .toLowerCase() ==
                                                trimmed;
                                            if (!editingOwn) {
                                              final jlp =
                                                  ref.read(jobListRiverpod);
                                              final jobDate = _selectedDate ??
                                                  DateTime.now();
                                              final sameMonth =
                                                  jlp.currentMonth.year ==
                                                          jobDate.year &&
                                                      jlp.currentMonth.month ==
                                                          jobDate.month;
                                              if (sameMonth) {
                                                final exists = jlp
                                                    .allJobListItems
                                                    .any((item) =>
                                                        item.client
                                                            .trim()
                                                            .toLowerCase() ==
                                                        trimmed);
                                                if (exists) {
                                                  return 'Client already exists this month — use a different name';
                                                }
                                              }
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
                                              labelText: 'Amount',
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
                                              if (value != null &&
                                                  value.isNotEmpty) {
                                                if (double.tryParse(value) ==
                                                    null) {
                                                  return 'Please enter a valid amount';
                                                }
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
                                              final trimmed =
                                                  value.trim().toLowerCase();
                                              final editingOwn = widget
                                                      .jobToEdit?.client
                                                      .trim()
                                                      .toLowerCase() ==
                                                  trimmed;
                                              if (!editingOwn) {
                                                final jlp =
                                                    ref.read(jobListRiverpod);
                                                final jobDate = _selectedDate ??
                                                    DateTime.now();
                                                final sameMonth = jlp
                                                            .currentMonth
                                                            .year ==
                                                        jobDate.year &&
                                                    jlp.currentMonth.month ==
                                                        jobDate.month;
                                                if (sameMonth) {
                                                  final exists = jlp
                                                      .allJobListItems
                                                      .any((item) =>
                                                          item.client
                                                              .trim()
                                                              .toLowerCase() ==
                                                          trimmed);
                                                  if (exists) {
                                                    return 'Client already exists this month — use a different name';
                                                  }
                                                }
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
                                        _buildAreaAutocomplete(),
                                        const SizedBox(height: 12),
                                        _buildJobStatusField(),
                                        const SizedBox(height: 12),
                                        _buildJobTypeField(),
                                      ],
                                    )
                                  : Row(
                                      children: [
                                        Flexible(
                                          child: _buildAreaAutocomplete(),
                                        ),
                                        const SizedBox(width: 12),
                                        Flexible(
                                          flex: 2,
                                          child: _buildJobStatusField(),
                                        ),
                                        const SizedBox(width: 12),
                                        Flexible(
                                          flex: 2,
                                          child: _buildJobTypeField(),
                                        ),
                                      ],
                                    ),
                              const SizedBox(height: 16),

                              // Row 3: Area, Quantity (conditional based on job type)
                              Row(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: (VehicleTrailerCombo
                                            .isVehicleJobType(_selectedJobType))
                                        ? _buildVehicleTrailerField()
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
                                    child: Builder(
                                      builder: (context) {
                                        final collectionProvider = ref
                                            .watch(collectionScheduleRiverpod);
                                        // Check if current selection has conflicts
                                        bool hasConflicts = false;
                                        String conflictMessage = '';

                                        if (_selectedDate != null &&
                                            _selectedVehicleTrailerCombo !=
                                                null &&
                                            VehicleTrailerCombo
                                                .isVehicleJobType(
                                                    _selectedJobType)) {
                                          final vehicleType =
                                              _selectedVehicleTrailerCombo!
                                                  .vehicleType;

                                          final occupiedSlots =
                                              collectionProvider
                                                  .getOccupiedTimeSlots(
                                                      vehicleType,
                                                      _selectedDate!,
                                                      excludeJobId:
                                                          widget.jobToEdit?.id);
                                          if (occupiedSlots.isNotEmpty) {
                                            hasConflicts = true;
                                            final vehicleName =
                                                vehicleType.name.toUpperCase();
                                            final slotCount =
                                                occupiedSlots.length;
                                            conflictMessage =
                                                '⚠️ $vehicleName has $slotCount time conflict${slotCount > 1 ? 's' : ''} - can still be booked';
                                          }
                                        }

                                        return FormField<DateTime>(
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
                                                final date =
                                                    await showDatePicker(
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
                                                        await showDialog<
                                                            TimeOfDay>(
                                                      context: context,
                                                      builder: (context) =>
                                                          Builder(
                                                        builder: (context) {
                                                          final collectionProvider =
                                                              ref.watch(
                                                                  collectionScheduleRiverpod);
                                                          // Get vehicle type and count occupied slots for header info
                                                          VehicleType?
                                                              vehicleType;
                                                          List<String>
                                                              occupiedSlots =
                                                              [];

                                                          if (_selectedVehicleTrailerCombo !=
                                                              null) {
                                                            vehicleType =
                                                                _selectedVehicleTrailerCombo!
                                                                    .vehicleType;

                                                            occupiedSlots =
                                                                collectionProvider
                                                                    .getOccupiedTimeSlots(
                                                              vehicleType,
                                                              date,
                                                              excludeJobId:
                                                                  widget
                                                                      .jobToEdit
                                                                      ?.id,
                                                            );
                                                          }

                                                          return AlertDialog(
                                                            title: Column(
                                                              crossAxisAlignment:
                                                                  CrossAxisAlignment
                                                                      .start,
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .min,
                                                              children: [
                                                                const Text(
                                                                    'Select Time'),
                                                                if (vehicleType !=
                                                                    null) ...[
                                                                  const SizedBox(
                                                                      height:
                                                                          4),
                                                                  Text(
                                                                    '${vehicleType.name.toUpperCase()} - ${DateFormat('dd MMM yyyy').format(date)}',
                                                                    style: const TextStyle(
                                                                        fontSize:
                                                                            14,
                                                                        fontWeight:
                                                                            FontWeight.normal),
                                                                  ),
                                                                  if (occupiedSlots
                                                                      .isNotEmpty) ...[
                                                                    const SizedBox(
                                                                        height:
                                                                            2),
                                                                    Text(
                                                                      '⚠️ ${occupiedSlots.length} time slot${occupiedSlots.length > 1 ? 's' : ''} have conflicts',
                                                                      style: const TextStyle(
                                                                          fontSize:
                                                                              12,
                                                                          color:
                                                                              Colors.orange),
                                                                    ),
                                                                  ],
                                                                ],
                                                              ],
                                                            ),
                                                            content: SizedBox(
                                                              width: 300,
                                                              height: 400,
                                                              child: ListView
                                                                  .builder(
                                                                itemCount:
                                                                    timeSlots
                                                                        .length,
                                                                itemBuilder:
                                                                    (context,
                                                                        index) {
                                                                  final time =
                                                                      timeSlots[
                                                                          index];
                                                                  final timeString =
                                                                      _formatTimeOfDay(
                                                                          time);

                                                                  // Check if this time slot is occupied for collection jobs
                                                                  bool
                                                                      isOccupied =
                                                                      false;
                                                                  String
                                                                      conflictDetails =
                                                                      '';
                                                                  Color
                                                                      conflictColor =
                                                                      Colors
                                                                          .red;

                                                                  if (VehicleTrailerCombo
                                                                      .isVehicleJobType(
                                                                          _selectedJobType)) {
                                                                    // Get vehicle type from quantity
                                                                    if (_selectedVehicleTrailerCombo !=
                                                                        null) {
                                                                      final vehicleType =
                                                                          _selectedVehicleTrailerCombo!
                                                                              .vehicleType;

                                                                      final occupiedSlots = collectionProvider.getOccupiedTimeSlots(
                                                                          vehicleType,
                                                                          date, // Use the newly selected date, not _selectedDate
                                                                          excludeJobId: widget
                                                                              .jobToEdit
                                                                              ?.id);
                                                                      isOccupied =
                                                                          occupiedSlots
                                                                              .contains(timeString);

                                                                      // Get details about the conflicting job
                                                                      if (isOccupied) {
                                                                        final conflictingJobs = collectionProvider
                                                                            .getJobsForDate(
                                                                                date)
                                                                            .where((job) =>
                                                                                job.vehicleType == vehicleType &&
                                                                                _jobOccupiesTimeSlot(job, timeString))
                                                                            .toList();

                                                                        if (conflictingJobs
                                                                            .isNotEmpty) {
                                                                          final job =
                                                                              conflictingJobs.first;
                                                                          final clientName = job.clients.isNotEmpty
                                                                              ? job.clients.first
                                                                              : 'Unknown Client';
                                                                          conflictDetails =
                                                                              'Booked by $clientName';

                                                                          // Different colors for different job types
                                                                          switch (
                                                                              job.jobType) {
                                                                            case 'junk collection':
                                                                              conflictColor = Colors.red;
                                                                              break;
                                                                            case 'furniture move':
                                                                              conflictColor = Colors.orange;
                                                                              break;
                                                                            case 'trailer towing':
                                                                              conflictColor = Colors.purple;
                                                                              break;
                                                                            default:
                                                                              conflictColor = Colors.red;
                                                                          }
                                                                        }
                                                                      }
                                                                    }
                                                                  }

                                                                  return Container(
                                                                    decoration:
                                                                        BoxDecoration(
                                                                      color: isOccupied
                                                                          ? conflictColor.withValues(
                                                                              alpha: 0.1)
                                                                          : null,
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                              4),
                                                                      border: isOccupied
                                                                          ? Border.all(
                                                                              color: conflictColor.withValues(alpha: 0.3))
                                                                          : null,
                                                                    ),
                                                                    child:
                                                                        ListTile(
                                                                      title:
                                                                          Text(
                                                                        _formatTimeOfDay(
                                                                            time),
                                                                        style:
                                                                            TextStyle(
                                                                          color: isOccupied
                                                                              ? conflictColor
                                                                              : null,
                                                                          fontWeight: isOccupied
                                                                              ? FontWeight.bold
                                                                              : null,
                                                                        ),
                                                                      ),
                                                                      subtitle: isOccupied
                                                                          ? Text(
                                                                              '⚠️ ${conflictDetails.isNotEmpty ? conflictDetails : 'Occupied'} (Click to override)',
                                                                              style: TextStyle(color: conflictColor, fontSize: 12),
                                                                            )
                                                                          : const Text(
                                                                              'Available',
                                                                              style: TextStyle(color: Colors.green, fontSize: 12),
                                                                            ),
                                                                      leading: isOccupied
                                                                          ? Icon(
                                                                              Icons.warning,
                                                                              color: conflictColor,
                                                                              size: 16,
                                                                            )
                                                                          : const Icon(
                                                                              Icons.schedule,
                                                                              color: Colors.green,
                                                                              size: 16,
                                                                            ),
                                                                      onTap: () =>
                                                                          Navigator.of(context)
                                                                              .pop(time),
                                                                    ),
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
                                                          );
                                                        },
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
                                                          : Icons
                                                              .calendar_today,
                                                      color: hasConflicts
                                                          ? Colors.orange
                                                          : null),
                                                  errorText: state.errorText ??
                                                      (hasConflicts
                                                          ? conflictMessage
                                                          : null),
                                                  helperText: hasConflicts
                                                      ? 'Click to view times (conflicts can be overridden)'
                                                      : null,
                                                  helperStyle: hasConflicts
                                                      ? const TextStyle(
                                                          color: Colors.orange)
                                                      : null,
                                                ),
                                                child: Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        _selectedDate != null
                                                            ? _needsTimeSelection(
                                                                    _selectedJobType)
                                                                ? DateFormat(
                                                                        'dd MMM, HH:mm')
                                                                    .format(
                                                                        _selectedDate!)
                                                                : DateFormat(
                                                                        'dd MMM yyyy')
                                                                    .format(
                                                                        _selectedDate!)
                                                            : _needsTimeSelection(
                                                                    _selectedJobType)
                                                                ? 'Select Date & Time'
                                                                : 'Select Distribution Date',
                                                        style: TextStyle(
                                                          color: hasConflicts
                                                              ? Colors.orange
                                                              : null,
                                                        ),
                                                      ),
                                                    ),
                                                    if (hasConflicts)
                                                      const Icon(
                                                        Icons.warning,
                                                        color: Colors.orange,
                                                        size: 16,
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
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

                              // Conditionally show fields based on job type flags.
                              // Non-Happy-Sun jobs get Quantity/Invoice/Report rows;
                              // Happy Sun jobs get the Tools Needed panel further down.
                              if (!(JobTypeProvider.instance
                                      ?.isHappySunService(_selectedJobType) ??
                                  false)) ...[
                                // Row 7: Quantity Distributed & Invoice Details.
                                // The quantity field is only shown when the
                                // selected job type tracks a quantity, and its
                                // label comes from the type's `quantityLabel`.
                                Row(
                                  children: [
                                    if (JobTypeProvider.instance
                                            ?.tracksQuantity(
                                                _selectedJobType) ??
                                        true) ...[
                                      Expanded(
                                        child: TextFormField(
                                          controller:
                                              _quantityDistributedController,
                                          decoration: InputDecoration(
                                            labelText: JobTypeProvider.instance
                                                    ?.quantityLabel(
                                                        _selectedJobType) ??
                                                'Quantity',
                                            border: const OutlineInputBorder(),
                                          ),
                                          keyboardType: TextInputType.number,
                                          inputFormatters: [
                                            FilteringTextInputFormatter
                                                .digitsOnly
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                    ],
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

                                // Row 8: Report Addresses & Who to Invoice
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

                              // Tools Needed button for Happy Sun-flagged types.
                              if (JobTypeProvider.instance
                                      ?.isHappySunService(_selectedJobType) ??
                                  false) ...[
                                const SizedBox(height: 16),
                                OutlinedButton.icon(
                                  onPressed: _showToolsDialog,
                                  icon: const Icon(Icons.build),
                                  label: Text(
                                    _toolsNeeded != null &&
                                            _toolsNeeded!.totalCount > 0
                                        ? 'Tools Needed (${_toolsNeeded!.totalCount})'
                                        : 'Add Tools Needed',
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ],
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
                            if (!isEditing &&
                                !_needsTimeSelection(
                                    _selectedJobType)) // Only show skip allocation for new jobs that don't need time selection
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
                            if (!isEditing &&
                                !_needsTimeSelection(_selectedJobType))
                              const SizedBox(height: 8),
                            if (isEditing &&
                                !_needsTimeSelection(
                                    _selectedJobType)) // Show automatic allocation for editing jobs that don't need time selection
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
                            if (isEditing &&
                                !_needsTimeSelection(_selectedJobType))
                              const SizedBox(height: 8),
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
                            if (!isEditing &&
                                !_needsTimeSelection(
                                    _selectedJobType)) // Only show skip allocation for new jobs that don't need time selection
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
                            if (isEditing &&
                                !_needsTimeSelection(
                                    _selectedJobType)) // Show automatic allocation for editing jobs that don't need time selection
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

  JobListItem _buildJobListItem() {
    final bool isNew = widget.jobToEdit == null;

    // Preserve existing updates, or initialize empty list
    List<JobListItemUpdate> currentUpdates =
        widget.jobToEdit?.updates.toList() ?? [];

    // Log creation if this is a new job
    if (isNew) {
      final authProvider = mounted ? ref.read(authRiverpod) : null;
      final userId = authProvider?.user?.uid ?? 'system';
      final userName = authProvider?.appUser?.name ??
          authProvider?.user?.displayName ??
          'System';

      currentUpdates.add(JobListItemUpdate(
        userId: userId,
        fieldName: 'created',
        oldValue: null,
        newValue: 'Job created',
        timestamp: DateTime.now(),
        userDisplayName: userName,
      ));
    }

    return JobListItem(
      id: widget.jobToEdit?.id ?? '',
      invoice: _invoiceController.text.trim(),
      amount: double.tryParse(_amountController.text) ?? 0.0,
      client: _clientController.text.trim(),
      jobStatusId: _selectedJobStatusId,
      invoiceStatusId: widget.jobToEdit?.invoiceStatusId ?? 'pending',
      jobTypeId: _selectedJobType,
      area: _areaController.text.trim(),
      quantity: int.tryParse(_quantityController.text) ?? 0,
      manDays: double.tryParse(_manDaysController.text) ?? 0.0,
      date: _selectedDate ?? DateTime.now(),
      collectionAddress: _collectionAddressController.text.trim(),
      collectionDate: _selectedCollectionDate ?? DateTime(2000, 1, 1),
      specialInstructions: _specialInstructionsController.text.trim(),
      quantityDistributed:
          int.tryParse(_quantityDistributedController.text) ?? 0,
      invoiceDetails: _invoiceDetailsController.text.trim(),
      reportAddresses: _reportAddressesController.text.trim(),
      whoToInvoice: _whoToInvoiceController.text.trim(),
      toolsNeeded: _toolsNeeded,
      updates: currentUpdates,
      customPolygons: widget.jobToEdit?.customPolygons ?? const [],
      reminders: widget.jobToEdit?.reminders ?? const [],
      collectionJobId: widget.jobToEdit?.collectionJobId ?? '',
      vehicleTrailerCombo: _selectedVehicleTrailerCombo?.name ?? '',
    );
  }

  /// Checks whether [clientName] already exists in the job list for the
  /// month of [_selectedDate].
  ///
  /// • Loaded month  → in-memory set, 0 extra reads.
  /// • Different month → single Firestore fetch (cached for the session).
  ///
  /// Returns an error message to show the user, or null if the name is free.
  Future<String?> _checkDuplicateClient() async {
    // Skip check when editing and the client name hasn't changed.
    final clientName = _clientController.text.trim();
    final editingOwn = widget.jobToEdit?.client.trim().toLowerCase() ==
        clientName.toLowerCase();
    if (editingOwn) return null;

    final jobDate = _selectedDate ?? DateTime.now();
    try {
      final existingClients =
          await ref.read(jobListRiverpod).fetchClientNamesForMonth(jobDate);
      if (existingClients.contains(clientName.toLowerCase())) {
        return 'Client "$clientName" already exists for that month — use a different name.';
      }
    } catch (e) {
      // Non-fatal: if the check fails (e.g. offline), let the save proceed.
      debugPrint('⚠️ Duplicate client check failed: $e');
    }
    return null;
  }

  void _saveJob() async {
    debugPrint('\n💾 AddEditJobDialog._saveJob: Started');
    debugPrint('   Job Type: $_selectedJobType');
    debugPrint('   Client: ${_clientController.text.trim()}');
    debugPrint(
        '   Tools Needed: ${_toolsNeeded != null ? "Yes (${_toolsNeeded!.totalCount} tools)" : "No"}');

    if (_formKey.currentState!.validate()) {
      // Async duplicate check — covers months not currently loaded in memory.
      final dupError = await _checkDuplicateClient();
      if (dupError != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(dupError), backgroundColor: Colors.red),
          );
        }
        return;
      }

      setState(() {
        _isProcessing = true;
      });

      debugPrint('   Creating JobListItem object...');
      final jobListItem = _buildJobListItem();
      debugPrint('   ✅ JobListItem created');
      debugPrint('   - Job Type: ${jobListItem.jobTypeId}');
      debugPrint('   - Has Tools: ${jobListItem.toolsNeeded != null}');

      try {
        // Offer address geocoding for jobs with a usable address.
        // Priority: `area` field (when it's a free-text address, not a map link)
        // → `collectionAddress` field. Skip if area is a URL/map-link.
        JobListItem finalJobListItem = jobListItem;
        CustomPolygon? addressPoint;

        final areaText = jobListItem.area.trim();
        final collectionText = jobListItem.collectionAddress.trim();
        final areaIsMapLink = _isMapLinkOrUrl(areaText);

        String? addressToSearch;
        if (areaText.isNotEmpty && !areaIsMapLink) {
          addressToSearch = areaText;
        } else if (collectionText.isNotEmpty) {
          addressToSearch = collectionText;
        }

        if (addressToSearch != null) {
          addressPoint = await _resolveAddressPoint(
            addressToSearch,
            _selectedJobType,
          );
          if (addressPoint != null) {
            // Attach the geocoded point to the job list item's custom polygons
            finalJobListItem = jobListItem.copyWith(
              customPolygons: [
                ...jobListItem.customPolygons,
                addressPoint,
              ],
            );
          }
        }

        // If editing existing job
        if (widget.jobToEdit != null) {
          debugPrint(
              '   📝 Editing existing job - returning JobListItem to caller');
          debugPrint(
              '   No direct DB write from dialog - JobList/JobListGrid handles update');
          // Check if this is a collection job and if time/date changed
          if (VehicleTrailerCombo.isVehicleJobType(_selectedJobType) &&
              widget.jobToEdit!.collectionJobId.isNotEmpty) {
            // Update the linked collection job if date/time changed
            // Collection job updates are now automatic via JobListProvider stream
          }
          Navigator.of(context).pop(finalJobListItem);
          return;
        }

        // For new jobs, run the assignment preview for ALL job types so the
        // user gets distributor allocation on the schedule. Vehicle/collection
        // jobs additionally appear on the collection schedule via JobListProvider.
        if (VehicleTrailerCombo.isVehicleJobType(_selectedJobType)) {
          debugPrint(
              '   🚚 Collection job type - showing assignment preview for schedule allocation');
        } else {
          debugPrint('   📅 Non-collection job - showing assignment preview');
        }
        await _showJobAssignmentPreview(finalJobListItem,
            addressPoint: addressPoint);
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
    debugPrint('\n💾 AddEditJobDialog._saveJobWithoutAllocation: Started');
    debugPrint(
        '   ⚠️ WARNING: This method calls JobListProvider.addJobListItem directly!');
    debugPrint('   Job Type: $_selectedJobType');

    if (_formKey.currentState!.validate()) {
      // Async duplicate check — covers months not currently loaded in memory.
      final dupError = await _checkDuplicateClient();
      if (dupError != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(dupError), backgroundColor: Colors.red),
          );
        }
        return;
      }

      setState(() {
        _isProcessing = true;
      });

      final jobListItem = _buildJobListItem();

      try {
        // Save the job to database but skip automatic schedule allocation.
        // Use `addJobListItemAndReturn` (instead of the void variant) so
        // the dialog can return the *saved* job — including its generated
        // Firestore id — to the caller. Callers like the Job-List "copy"
        // flow rely on that id to clone the linked map afterwards.
        debugPrint(
            '   🔥 Calling JobListProvider.addJobListItemAndReturn (direct DB write)');
        debugPrint(
            '   This will trigger Happy Sun sync if window/solar cleaning!');
        final savedJob = await ref
            .read(jobListRiverpod)
            .addJobListItemAndReturn(jobListItem);
        debugPrint(
            '   ✅ JobListProvider.addJobListItemAndReturn completed (id=${savedJob.id})');

        // Return the saved job (with id) plus the skip-allocation flag.
        Navigator.of(context).pop({'job': savedJob, 'skipAllocation': true});
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error saving job: $e'),
              backgroundColor: Colors.red,
            ),
          );
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

  void _saveJobWithAutomaticAllocation() async {
    if (_formKey.currentState!.validate()) {
      // Async duplicate check — covers months not currently loaded in memory.
      final dupError = await _checkDuplicateClient();
      if (dupError != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(dupError), backgroundColor: Colors.red),
          );
        }
        return;
      }

      setState(() {
        _isProcessing = true;
      });

      final jobListItem = _buildJobListItem();

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

  /// Returns true if [text] looks like a URL or a shareable-map link (and
  /// therefore is NOT a free-text street address that should be geocoded).
  bool _isMapLinkOrUrl(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return false;
    return t.startsWith('http://') ||
        t.startsWith('https://') ||
        t.contains('clm-maps.web.app/map/') ||
        t.contains('google.com/maps') ||
        t.contains('maps.app.goo.gl') ||
        t.contains('goo.gl/maps');
  }

  Future<CustomPolygon?> _resolveAddressPoint(
      String address, String jobTypeId) async {
    if (!mounted) return null;

    final isHappySun =
        JobTypeProvider.instance?.isHappySunService(jobTypeId) ?? false;
    final isFurniture = jobTypeId == 'furnitureMove';

    PointCategory category;
    String label;
    if (isHappySun) {
      category = PointCategory.cleaning;
      label = 'Cleaning Address';
    } else if (isFurniture) {
      category = PointCategory.loading;
      label = 'Furniture Address';
    } else {
      category = PointCategory.pickup;
      label = 'Collection Address';
    }

    final result = await showDialog<AddressPointResult?>(
      context: context,
      builder: (_) => AddressPointSearchDialog(
        initialAddress: address,
        label: label,
        category: category,
      ),
    );

    return result?.toCustomPolygon();
  }

  Future<void> _showJobAssignmentPreview(JobListItem jobListItem,
      {CustomPolygon? addressPoint}) async {
    try {
      // Get the schedule provider
      final scheduleProvider = ref.read(scheduleRiverpod);

      // Create the assignment service
      final assignmentService = JobAssignmentService(scheduleProvider);
      final areaText = jobListItem.area.trim();
      final assignmentWorkArea =
          areaText.isNotEmpty && !_isMapLinkOrUrl(areaText)
              ? areaText
              : 'To be assigned';

      // Calculate the job assignments
      final assignments = assignmentService.calculateJobAssignments(
        client: jobListItem.client,
        manDays: jobListItem.manDays,
        startDate: jobListItem.date,
        workingArea: assignmentWorkArea,
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
          await _createScheduleJobs(assignmentService, assignments,
              addressPoint: addressPoint);

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

  Future<void> _createScheduleJobs(
      JobAssignmentService assignmentService, List<JobAssignment> assignments,
      {CustomPolygon? addressPoint}) async {
    try {
      final scheduleProvider = ref.read(scheduleRiverpod);

      // Convert assignments to Job objects
      var jobs = assignmentService.createJobsFromAssignments(assignments);

      // Inject the geocoded address point into each schedule job's workMaps
      if (addressPoint != null) {
        jobs = jobs
            .map((j) => j.copyWith(workMaps: [...j.workMaps, addressPoint]))
            .toList();
      }

      // Add each job to the schedule
      for (final job in jobs) {
        await scheduleProvider.addJobWithUndo(job, job.date);
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

  // Helper methods for time selection
  bool _needsTimeSelection(String jobTypeId) {
    final provider = JobTypeProvider.instance;
    if (provider == null) return false;
    return provider.needsTimeSlot(jobTypeId);
  }

  List<TimeOfDay> _getAvailableTimeSlots() {
    final slots = <TimeOfDay>[];
    // Start with 07:30
    slots.add(const TimeOfDay(hour: 7, minute: 30));
    // Generate 30-minute intervals from 08:00 AM to 20:00 PM (8:00 PM)
    for (int hour = 8; hour <= 20; hour++) {
      slots.add(TimeOfDay(hour: hour, minute: 0));
      if (hour < 20) {
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

  // Helper method to check if a job occupies a specific time slot
  bool _jobOccupiesTimeSlot(CollectionJob job, String timeSlot) {
    const availableTimeSlots = [
      "07:30",
      "08:00",
      "08:30",
      "09:00",
      "09:30",
      "10:00",
      "10:30",
      "11:00",
      "11:30",
      "12:00",
      "12:30",
      "13:00",
      "13:30",
      "14:00",
      "14:30",
      "15:00",
      "15:30",
      "16:00",
      "16:30",
      "17:00",
      "17:30",
      "18:00",
      "18:30",
      "19:00",
      "19:30",
      "20:00"
    ];

    final jobStartIndex = availableTimeSlots.indexOf(job.timeSlot);
    final checkIndex = availableTimeSlots.indexOf(timeSlot);

    if (jobStartIndex == -1 || checkIndex == -1) {
      return job.timeSlot == timeSlot; // Fallback to exact match
    }

    // Check if the timeSlot falls within the job's duration
    return checkIndex >= jobStartIndex &&
        checkIndex < (jobStartIndex + job.timeSlots);
  }

  void _showToolsDialog() async {
    debugPrint('\n🔧 AddEditJobDialog._showToolsDialog: Opening tools dialog');
    debugPrint('   Job Type: $_selectedJobType');
    debugPrint(
        '   Current tools: ${_toolsNeeded != null ? "${_toolsNeeded!.totalCount} tools" : "None"}');

    // Validate form before opening tools dialog
    if (!_formKey.currentState!.validate()) {
      // Scroll to top to show validation errors
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      return;
    }

    final inventoryProvider = ref.read(inventoryRiverpod);
    final toolSettingsProvider = ref.read(toolSettingsRiverpod);

    // Initialize inventory if needed
    if (inventoryProvider.tools.isEmpty && !inventoryProvider.isLoading) {
      await inventoryProvider.initialize();
    }

    // Initialize tool settings if needed
    if (toolSettingsProvider.settings.teamTools.isEmpty &&
        toolSettingsProvider.settings.individualTools.isEmpty) {
      await toolSettingsProvider.loadSettings();
    }

    if (!mounted) return;

    // Auto-calculate tools based on manDays if not already set
    CategorizedTools initialTools;
    if (_toolsNeeded == null) {
      final numberOfCleaners =
          (double.tryParse(_manDaysController.text) ?? 0).ceil();

      if (numberOfCleaners > 0) {
        // Calculate categorized tools: team tools (constant) + individual tools (per cleaner) + accessories
        initialTools = toolSettingsProvider.calculateCategorizedTools(
          numberOfCleaners,
          inventoryProvider.tools,
        );

        debugPrint(
            '🔧 Auto-calculated tools for $numberOfCleaners cleaner(s):');
        debugPrint('   Team tools: ${initialTools.teamTools.length} groups');
        debugPrint(
            '   Individual tools: ${initialTools.individualTools.length} groups');
        debugPrint('   Extras: ${initialTools.extras.length} groups');
        debugPrint('   Accessories: ${initialTools.accessories.length} groups');
      } else {
        initialTools = CategorizedTools.empty();
      }
    } else {
      initialTools = _toolsNeeded!;
    }

    // Show tools dialog
    final result = await showDialog<CategorizedTools>(
      context: context,
      builder: (context) => HappySunToolsDialog(
        currentTools: initialTools,
        availableTools: inventoryProvider.tools,
      ),
    );

    if (result != null) {
      debugPrint('   ✅ Tools dialog returned with tools');
      debugPrint('   Team tools: ${result.teamTools.length}');
      debugPrint('   Individual tools: ${result.individualTools.length}');
      debugPrint('   Extras: ${result.extras.length}');
      debugPrint('   Accessories: ${result.accessories.length}');
      debugPrint('   Total count: ${result.totalCount}');
      setState(() {
        _toolsNeeded = result;
      });
    } else {
      debugPrint('   ❌ Tools dialog cancelled');
    }
  }
}

/// Simple data class for map name + share URL pairs used in autocomplete.
class _MapSuggestion {
  final String name;
  final String url;
  const _MapSuggestion({required this.name, required this.url});
}

/// Outlined tap-to-open field used for all picker dropdowns in the dialog.
/// Provides a unified visual: colored accent dot, label text, and chevron.
class _PickerFieldShell extends StatelessWidget {
  final String label;
  final Color accent;
  final Widget? leading;
  final String text;
  final bool isPlaceholder;
  final void Function(BuildContext anchorContext) onTap;

  const _PickerFieldShell({
    required this.label,
    required this.accent,
    required this.text,
    required this.onTap,
    this.leading,
    this.isPlaceholder = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Builder(
      builder: (ctx) => InkWell(
        onTap: () => onTap(ctx),
        borderRadius: BorderRadius.circular(6),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accent,
                      Color.lerp(accent, Colors.black, 0.2) ?? accent,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.25),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: leading == null ? null : Center(child: leading!),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isPlaceholder ? theme.hintColor : null,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.keyboard_arrow_down, size: 22, color: theme.hintColor),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact single-line picker row used by the status and vehicle-trailer
/// menus (color dot + optional icon + label + check when selected).
class _SimplePickerRow extends StatelessWidget {
  final Color color;
  final String label;
  final bool selected;
  final IconData? icon;

  const _SimplePickerRow({
    required this.color,
    required this.label,
    required this.selected,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor =
        color.computeLuminance() > 0.6 ? Colors.black87 : Colors.white;
    final bg = selected ? color.withValues(alpha: 0.14) : Colors.transparent;

    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
            child: icon == null ? null : Icon(icon, size: 13, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (selected)
            Icon(Icons.check, size: 18, color: color)
          else
            const SizedBox(width: 18),
        ],
      ),
    );
  }
}

/// Narrow job-type menu row: left accent stripe, gradient avatar, label,
/// and a small wrap of behaviour-flag chips underneath.
class _JobTypeRow extends StatelessWidget {
  final CustomJobType type;
  final IconData icon;
  final bool selected;

  const _JobTypeRow({
    required this.type,
    required this.icon,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = type.colorValue != null
        ? Color(type.colorValue!)
        : theme.colorScheme.primary;
    final iconColor =
        accent.computeLuminance() > 0.6 ? Colors.black87 : Colors.white;

    final chips = <Widget>[];
    if (type.needsTimeSlot) {
      chips.add(const _FlagChip(
          icon: Icons.schedule, label: 'Time', color: Colors.indigo));
    }
    if (type.appearsOnCollectionSchedule) {
      chips.add(const _FlagChip(
          icon: Icons.local_shipping, label: 'Collection', color: Colors.teal));
    }
    if (type.isHappySunService) {
      chips.add(const _FlagChip(
          icon: Icons.wb_sunny_outlined,
          label: 'Happy Sun',
          color: Colors.orange));
    }
    if (type.tracksQuantity) {
      chips.add(_FlagChip(
          icon: Icons.numbers,
          label: type.quantityLabel,
          color: Colors.blueGrey));
    }

    final bg = selected ? accent.withValues(alpha: 0.12) : Colors.transparent;

    return IntrinsicHeight(
      child: Container(
        color: bg,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left accent stripe
            Container(width: 4, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            accent,
                            Color.lerp(accent, Colors.black, 0.2) ?? accent,
                          ],
                        ),
                      ),
                      child: Icon(icon, size: 16, color: iconColor),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            type.label,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (chips.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 4,
                              runSpacing: 3,
                              children: chips,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (selected)
                      Icon(Icons.check_circle, size: 18, color: accent),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FlagChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _FlagChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
