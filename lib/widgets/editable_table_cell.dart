import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../models/job_list_item.dart';
import '../models/collection_job.dart';
import '../providers/scale_provider.dart';
import '../providers/collection_schedule_provider.dart';

class EditableTableCell extends StatefulWidget {
  final String value;
  final Function(String) onSave;
  final String? Function(String?)? validator;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int maxLines;
  final double? width;
  final bool showTooltip;
  final Color? textColor;

  const EditableTableCell({
    super.key,
    required this.value,
    required this.onSave,
    this.validator,
    this.keyboardType = TextInputType.text,
    this.inputFormatters,
    this.maxLines = 1,
    this.width,
    this.showTooltip = false,
    this.textColor,
  });

  @override
  State<EditableTableCell> createState() => _EditableTableCellState();
}

class _EditableTableCellState extends State<EditableTableCell> {
  bool _isEditing = false;
  late TextEditingController _controller;
  late FocusNode _focusNode;
  late String _originalValue;

  @override
  void initState() {
    super.initState();
    _originalValue = widget.value;
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startEditing() {
    // Capture the original value at the start of editing
    _originalValue = widget.value;
    _controller.text = widget.value;

    setState(() {
      _isEditing = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _saveAndExit() {
    final currentValue = _controller.text;

    // Validate the input
    if (widget.validator != null) {
      final error = widget.validator!(currentValue);
      if (error != null) {
        // Show error and don't save
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
        return;
      }
    }

    // Only call onSave if the value actually changed
    if (currentValue != _originalValue) {
      widget.onSave(currentValue);
      print(
          'EditableTableCell: Value changed from "$_originalValue" to "$currentValue"');
    } else {
      print('EditableTableCell: No change detected, skipping save');
    }

    setState(() {
      _isEditing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ScaleProvider>(
      builder: (context, scaleProvider, child) {
        if (_isEditing) {
          return SizedBox(
            width: widget.width,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              keyboardType: widget.keyboardType,
              inputFormatters: widget.inputFormatters,
              maxLines: widget.maxLines,
              style: TextStyle(
                  fontSize: scaleProvider.mediumFontSize,
                  fontWeight: FontWeight.bold,
                  color: Colors.black),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _saveAndExit(),
              onTapOutside: (_) => _saveAndExit(),
            ),
          );
        }

        return SizedBox(
          width: widget.width,
          child: InkWell(
            onTap: _startEditing,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: widget.showTooltip && widget.value.isNotEmpty
                  ? Tooltip(
                      message: widget.value,
                      textStyle: TextStyle(
                          fontSize: scaleProvider.largeFontSize,
                          color: Colors.white),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        widget.value.isEmpty ? 'Click to edit' : widget.value,
                        style: TextStyle(
                          fontSize: scaleProvider.mediumFontSize,
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontStyle:
                              widget.value.isEmpty ? FontStyle.italic : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: widget.maxLines,
                      ),
                    )
                  : Text(
                      widget.value.isEmpty ? 'Click to edit' : widget.value,
                      style: TextStyle(
                        fontSize: scaleProvider.mediumFontSize,
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontStyle:
                            widget.value.isEmpty ? FontStyle.italic : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: widget.maxLines,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class EditableDateCell extends StatelessWidget {
  final DateTime value;
  final Function(DateTime) onSave;
  final double? width;
  final JobType? jobType;
  final Map<String, dynamic>? jobData;

  const EditableDateCell({
    super.key,
    required this.value,
    required this.onSave,
    this.width,
    this.jobType,
    this.jobData,
  });

  bool _needsTimeDisplay() {
    return jobType == JobType.junkCollection ||
        jobType == JobType.furnitureMove ||
        jobType == JobType.trailerTowing ||
        jobType == JobType.windowCleaning ||
        jobType == JobType.solarPanelCleaning;
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

  @override
  Widget build(BuildContext context) {
    return Consumer<ScaleProvider>(
      builder: (context, scaleProvider, child) {
        return SizedBox(
          width: width,
          child: InkWell(
            onTap: () async {
              final date = await showDatePicker(
                context: context,
                initialDate: value,
                firstDate: DateTime(2025),
                lastDate: DateTime(2030),
              );
              if (date != null) {
                DateTime finalDate = date;

                // If this job type needs time selection, show time picker
                if (_needsTimeDisplay()) {
                  final timeSlots = _getAvailableTimeSlots();
                  final selectedTime = await showDialog<TimeOfDay>(
                    context: context,
                    builder: (context) => Consumer<CollectionScheduleProvider>(
                      builder: (context, collectionProvider, child) =>
                          AlertDialog(
                        title: const Text('Select Time'),
                        content: SizedBox(
                          width: 300,
                          height: 400,
                          child: ListView.builder(
                            itemCount: timeSlots.length,
                            itemBuilder: (context, index) {
                              final time = timeSlots[index];
                              final timeString = _formatTimeOfDay(time);

                              // Check if this time slot is occupied for collection jobs
                              bool isOccupied = false;

                              if (jobType == JobType.junkCollection ||
                                  jobType == JobType.furnitureMove ||
                                  jobType == JobType.trailerTowing) {
                                // Try to get vehicle type from the job data
                                if (jobData != null) {
                                  VehicleType? vehicleType;

                                  // Extract vehicle type from existing job data
                                  if (jobData!.containsKey('vehicleType')) {
                                    final vehicleTypeString =
                                        jobData!['vehicleType'];
                                    if (vehicleTypeString == 'hyundai') {
                                      vehicleType = VehicleType.hyundai;
                                    } else if (vehicleTypeString ==
                                        'mahindra') {
                                      vehicleType = VehicleType.mahindra;
                                    } else if (vehicleTypeString == 'nissan') {
                                      vehicleType = VehicleType.nissan;
                                    }
                                  } else if (jobData!.containsKey('quantity')) {
                                    // Fallback: get vehicle type from quantity
                                    final quantity =
                                        jobData!['quantity'] as int? ?? 1;
                                    if (quantity >= 1 && quantity <= 3) {
                                      vehicleType = VehicleType.hyundai;
                                    } else if (quantity >= 4 && quantity <= 6) {
                                      vehicleType = VehicleType.mahindra;
                                    } else if (quantity >= 7 && quantity <= 9) {
                                      vehicleType = VehicleType.nissan;
                                    }
                                  }

                                  if (vehicleType != null) {
                                    final occupiedSlots = collectionProvider
                                        .getOccupiedTimeSlots(vehicleType, date,
                                            excludeJobId: jobData!['id']);
                                    isOccupied =
                                        occupiedSlots.contains(timeString);
                                  }
                                }
                              }

                              return ListTile(
                                title: Text(
                                  _formatTimeOfDay(time),
                                  style: TextStyle(
                                    color: isOccupied ? Colors.red : null,
                                    fontWeight:
                                        isOccupied ? FontWeight.bold : null,
                                  ),
                                ),
                                subtitle: isOccupied
                                    ? const Text(
                                        'Occupied',
                                        style: TextStyle(
                                            color: Colors.red, fontSize: 12),
                                      )
                                    : null,
                                leading: isOccupied
                                    ? const Icon(
                                        Icons.block,
                                        color: Colors.red,
                                        size: 16,
                                      )
                                    : null,
                                enabled: !isOccupied,
                                onTap: isOccupied
                                    ? null
                                    : () => Navigator.of(context).pop(time),
                              );
                            },
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
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

                if (finalDate != value) {
                  // Only call onSave if the date/time actually changed
                  print(
                      'EditableDateCell: Date changed from "${value.toIso8601String()}" to "${finalDate.toIso8601String()}"');
                  onSave(finalDate);
                } else {
                  print('EditableDateCell: No change detected, skipping save');
                }
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Check if this is the default "not set" date
                  value.year == 2000 && value.month == 1 && value.day == 1
                      ? Text(
                          'Not Set',
                          style: TextStyle(
                            fontSize: scaleProvider.mediumFontSize,
                            color: Colors.grey[600],
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      : _needsTimeDisplay()
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  DateFormat('dd MMM').format(value),
                                  style: TextStyle(
                                    fontSize: scaleProvider.mediumFontSize,
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  DateFormat('h:mm a').format(value),
                                  style: TextStyle(
                                      fontSize: scaleProvider.mediumFontSize,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black),
                                ),
                              ],
                            )
                          : Text(
                              DateFormat('dd MMM').format(value),
                              style: TextStyle(
                                fontSize: scaleProvider.mediumFontSize,
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class LinkCell extends StatefulWidget {
  final String value;
  final Function(String) onSave;
  final String? Function(String?)? validator;
  final int maxLines;
  final double? width;

  const LinkCell({
    super.key,
    required this.value,
    required this.onSave,
    this.validator,
    this.maxLines = 1,
    this.width,
  });

  @override
  State<LinkCell> createState() => _LinkCellState();
}

class _LinkCellState extends State<LinkCell> {
  bool _isEditing = false;
  bool _isHovering = false;
  late TextEditingController _controller;
  late FocusNode _focusNode;
  late String _originalValue;

  @override
  void initState() {
    super.initState();
    _originalValue = widget.value;
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool _isValidUrl(String url) {
    if (url.isEmpty) return false;
    try {
      // Check if it looks like a URL (contains a domain)
      if (url.contains('.') && !url.contains(' ')) {
        final formattedUrl = _formatUrlForDisplay(url);
        final uri = Uri.parse(formattedUrl);
        return uri.hasScheme &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  String _formatUrlForDisplay(String url) {
    if (url.isEmpty) return url;

    // Add https:// if no scheme is present
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return 'https://$url';
    }
    return url;
  }

  Future<void> _launchUrl() async {
    final formattedUrl = _formatUrlForDisplay(widget.value);
    if (_isValidUrl(formattedUrl)) {
      final uri = Uri.parse(formattedUrl);
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open link: $e')),
          );
        }
      }
    }
  }

  void _startEditing() {
    // Capture the original value at the start of editing
    _originalValue = widget.value;
    _controller.text = widget.value;

    setState(() {
      _isEditing = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _saveAndExit() {
    final currentValue = _controller.text;

    // Validate the input
    if (widget.validator != null) {
      final error = widget.validator!(currentValue);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
        return;
      }
    }

    // Only call onSave if the value actually changed
    if (currentValue != _originalValue) {
      widget.onSave(currentValue);
      print(
          'LinkCell: Value changed from "$_originalValue" to "$currentValue"');
    } else {
      print('LinkCell: No change detected, skipping save');
    }

    setState(() {
      _isEditing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ScaleProvider>(
      builder: (context, scaleProvider, child) {
        if (_isEditing) {
          return SizedBox(
            width: widget.width,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              keyboardType: TextInputType.url,
              maxLines: widget.maxLines,
              style: TextStyle(
                  fontSize: scaleProvider.mediumFontSize,
                  color: Colors.black,
                  fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                border: OutlineInputBorder(),
                hintText: 'Enter URL (e.g., google.com)',
              ),
              onSubmitted: (_) => _saveAndExit(),
              onTapOutside: (_) => _saveAndExit(),
            ),
          );
        }

        final formattedUrl = _formatUrlForDisplay(widget.value);
        final isValidLink = _isValidUrl(formattedUrl);

        return SizedBox(
          width: widget.width,
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovering = true),
            onExit: (_) => setState(() => _isHovering = false),
            child: Tooltip(
              message: isValidLink
                  ? 'Click to open: $formattedUrl'
                  : widget.value.isEmpty
                      ? 'Click to add link'
                      : 'Click to edit link',
              waitDuration: const Duration(milliseconds: 500),
              child: GestureDetector(
                onTap: isValidLink ? _launchUrl : _startEditing,
                onSecondaryTap: _startEditing,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    border: !isValidLink && _isHovering
                        ? Border.all(color: Colors.black, width: 1)
                        : null,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Expanded(
                        child: Text(
                          widget.value.isEmpty
                              ? 'Click to add link'
                              : widget.value,
                          style: TextStyle(
                            fontSize: scaleProvider.mediumFontSize,
                            color: isValidLink ? Colors.blue : Colors.black,
                            fontWeight: FontWeight.bold,
                            fontStyle:
                                widget.value.isEmpty ? FontStyle.italic : null,
                            decoration: isValidLink && _isHovering
                                ? TextDecoration.underline
                                : null,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: widget.maxLines,
                        ),
                      ),
                      if (isValidLink) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.open_in_new,
                          size: 12,
                          color: Colors.blueAccent,
                        ),
                      ] else if (widget.value.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.edit,
                          size: 12,
                          color: Colors.black,
                        ),
                      ] else if (_isHovering) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.add_link,
                          size: 12,
                          color: Colors.black,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class EditableVehicleComboCell extends StatefulWidget {
  final int quantity;
  final JobType jobType;
  final Function(int) onSave;
  final double? width;

  const EditableVehicleComboCell({
    super.key,
    required this.quantity,
    required this.jobType,
    required this.onSave,
    this.width,
  });

  @override
  State<EditableVehicleComboCell> createState() =>
      _EditableVehicleComboCellState();
}

class _EditableVehicleComboCellState extends State<EditableVehicleComboCell> {
  bool _isEditing = false;
  String? _selectedCombo;

  @override
  void initState() {
    super.initState();
    _selectedCombo = _getVehicleTrailerComboFromQuantity(widget.quantity);
    // If no valid combo found, default to first option
    if (_selectedCombo == null && _needsVehicleCombo(widget.jobType)) {
      _selectedCombo = _getVehicleTrailerCombinations().first;
    }
  }

  // Helper methods for vehicle/trailer combinations
  List<String> _getVehicleTrailerCombinations() {
    // For trailer towing, only show no-trailer combinations
    if (widget.jobType == JobType.trailerTowing) {
      return [
        'Hyundai - No Trailer',
        'Mahindra - No Trailer',
        'Nissan - No Trailer',
      ];
    }

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

  bool _needsVehicleCombo(JobType jobType) {
    return jobType == JobType.junkCollection ||
        jobType == JobType.furnitureMove ||
        jobType == JobType.trailerTowing;
  }

  void _saveChanges() {
    if (_selectedCombo != null) {
      final newQuantity = _getQuantityFromVehicleTrailerCombo(_selectedCombo);
      widget.onSave(newQuantity);
    }
    setState(() {
      _isEditing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ScaleProvider>(
      builder: (context, scaleProvider, child) {
        if (!_needsVehicleCombo(widget.jobType)) {
          // For non-vehicle combo job types, show simple quantity
          return SizedBox(
            width: widget.width,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
              child: Text(
                widget.quantity.toString(),
                style: TextStyle(
                    fontSize: scaleProvider.mediumFontSize,
                    fontWeight: FontWeight.bold,
                    color: Colors.black),
              ),
            ),
          );
        }

        if (_isEditing) {
          return SizedBox(
            width: widget.width,
            child: Container(
              padding: const EdgeInsets.all(2.0),
              child: DropdownButtonFormField<String>(
                initialValue: _selectedCombo,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  border: OutlineInputBorder(),
                ),
                style: TextStyle(
                    fontSize: scaleProvider.mediumFontSize,
                    fontWeight: FontWeight.bold),
                isExpanded: true,
                items: _getVehicleTrailerCombinations().map((combo) {
                  return DropdownMenuItem<String>(
                    value: combo,
                    child: Text(
                      combo,
                      style: TextStyle(fontSize: scaleProvider.mediumFontSize),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _selectedCombo = value;
                    });
                    // Auto-save when selection is made
                    _saveChanges();
                  }
                },
              ),
            ),
          );
        }

        return SizedBox(
          width: widget.width,
          child: InkWell(
            onTap: () {
              setState(() {
                _isEditing = true;
              });
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.transparent),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _selectedCombo ?? widget.quantity.toString(),
                      style: TextStyle(
                          fontSize: scaleProvider.mediumFontSize,
                          fontWeight: FontWeight.bold,
                          color: Colors.black),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                  const Icon(
                    Icons.arrow_drop_down,
                    size: 16,
                    color: Colors.black,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
