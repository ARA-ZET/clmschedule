import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/collection_job.dart';
import '../providers/job_type_provider.dart';
import '../providers/scale_provider.dart';
import '../providers/collection_schedule_provider.dart';

class EditableTableCell extends riverpod.ConsumerStatefulWidget {
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
  riverpod.ConsumerState<EditableTableCell> createState() =>
      _EditableTableCellState();
}

class _EditableTableCellState
    extends riverpod.ConsumerState<EditableTableCell> {
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
    return riverpod.Consumer(
      builder: (context, ref, child) {
        final scaleProvider = ref.watch(scaleRiverpod);
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
  final String? jobTypeId;
  final Map<String, dynamic>? jobData;

  const EditableDateCell({
    super.key,
    required this.value,
    required this.onSave,
    this.width,
    this.jobTypeId,
    this.jobData,
  });

  bool _needsTimeDisplay() {
    final provider = JobTypeProvider.instance;
    if (provider == null || jobTypeId == null) return false;
    return provider.needsTimeSlot(jobTypeId!);
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
    return riverpod.Consumer(
      builder: (context, ref, child) {
        final scaleProvider = ref.watch(scaleRiverpod);
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
                    builder: (context) => Builder(
                      builder: (context) {
                        final collectionProvider =
                            ref.watch(collectionScheduleRiverpod);
                        // Get occupied time slots for conflict info
                        final occupiedSlots = <String>[];
                        if (jobData != null &&
                            jobTypeId != null &&
                            VehicleTrailerCombo.isVehicleJobType(jobTypeId!)) {
                          VehicleType? vehicleType;

                          if (jobData!.containsKey('vehicleType')) {
                            final vehicleTypeString = jobData!['vehicleType'];
                            if (vehicleTypeString == 'hyundai') {
                              vehicleType = VehicleType.hyundai;
                            } else if (vehicleTypeString == 'mahindra') {
                              vehicleType = VehicleType.mahindra;
                            } else if (vehicleTypeString == 'nissan') {
                              vehicleType = VehicleType.nissan;
                            }
                          }

                          if (vehicleType != null) {
                            occupiedSlots.addAll(collectionProvider
                                .getOccupiedTimeSlots(vehicleType, date,
                                    excludeJobId: jobData!['id']));
                          }
                        }

                        return AlertDialog(
                          title: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Select Time'),
                              if (jobData != null &&
                                  jobTypeId != null &&
                                  VehicleTrailerCombo.isVehicleJobType(
                                      jobTypeId!)) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '${jobData!['vehicleType']?.toString().toUpperCase() ?? 'VEHICLE'} - ${DateFormat('dd MMM yyyy').format(date)}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: Colors.grey[600],
                                  ),
                                ),
                                if (occupiedSlots.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    '⚠️ ${occupiedSlots.length} time slot${occupiedSlots.length > 1 ? 's' : ''} have conflicts',
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.orange),
                                  ),
                                ],
                              ],
                            ],
                          ),
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
                                String conflictDetails = '';
                                Color conflictColor = Colors.red;

                                if (jobTypeId != null &&
                                    VehicleTrailerCombo.isVehicleJobType(
                                        jobTypeId!)) {
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
                                      } else if (vehicleTypeString ==
                                          'nissan') {
                                        vehicleType = VehicleType.nissan;
                                      }
                                    } else if (jobData!
                                        .containsKey('quantity')) {
                                      // Fallback: get vehicle type from quantity
                                      final quantity =
                                          (jobData!['quantity'] as num?)
                                                  ?.toInt() ??
                                              1;
                                      if (quantity >= 1 && quantity <= 3) {
                                        vehicleType = VehicleType.hyundai;
                                      } else if (quantity >= 4 &&
                                          quantity <= 6) {
                                        vehicleType = VehicleType.mahindra;
                                      } else if (quantity >= 7 &&
                                          quantity <= 9) {
                                        vehicleType = VehicleType.nissan;
                                      }
                                    }

                                    if (vehicleType != null) {
                                      final occupiedSlots = collectionProvider
                                          .getOccupiedTimeSlots(
                                              vehicleType, date,
                                              excludeJobId: jobData!['id']);
                                      isOccupied =
                                          occupiedSlots.contains(timeString);

                                      // Get details about the conflicting job
                                      if (isOccupied) {
                                        final conflictingJobs =
                                            collectionProvider
                                                .getJobsForDate(date)
                                                .where((job) =>
                                                    job.vehicleType ==
                                                        vehicleType &&
                                                    _jobOccupiesTimeSlot(
                                                        job, timeString))
                                                .toList();

                                        if (conflictingJobs.isNotEmpty) {
                                          final job = conflictingJobs.first;
                                          final clientName =
                                              job.clients.isNotEmpty
                                                  ? job.clients.first
                                                  : 'Unknown Client';
                                          conflictDetails =
                                              'Booked by $clientName';

                                          // Different colors for different job types
                                          switch (job.jobType) {
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
                                }

                                return Container(
                                  decoration: BoxDecoration(
                                    color: isOccupied
                                        ? conflictColor.withValues(alpha: 0.1)
                                        : null,
                                    borderRadius: BorderRadius.circular(4),
                                    border: isOccupied
                                        ? Border.all(
                                            color: conflictColor.withValues(
                                                alpha: 0.3))
                                        : null,
                                  ),
                                  child: ListTile(
                                    title: Text(
                                      _formatTimeOfDay(time),
                                      style: TextStyle(
                                        color:
                                            isOccupied ? conflictColor : null,
                                        fontWeight:
                                            isOccupied ? FontWeight.bold : null,
                                      ),
                                    ),
                                    subtitle: isOccupied
                                        ? Text(
                                            '⚠️ ${conflictDetails.isNotEmpty ? conflictDetails : 'Occupied'} (Click to override)',
                                            style: TextStyle(
                                                color: conflictColor,
                                                fontSize: 12),
                                          )
                                        : const Text(
                                            'Available',
                                            style: TextStyle(
                                                color: Colors.green,
                                                fontSize: 12),
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
                                        Navigator.of(context).pop(time),
                                  ),
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
}

class LinkCell extends riverpod.ConsumerStatefulWidget {
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
  riverpod.ConsumerState<LinkCell> createState() => _LinkCellState();
}

class _LinkCellState extends riverpod.ConsumerState<LinkCell> {
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
    return riverpod.Consumer(
      builder: (context, ref, child) {
        final scaleProvider = ref.watch(scaleRiverpod);
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

class EditableVehicleComboCell extends riverpod.ConsumerStatefulWidget {
  final int quantity;
  final String vehicleTrailerCombo;
  final String jobTypeId;
  final Function(int quantity, String vehicleTrailerCombo) onSave;
  final double? width;

  const EditableVehicleComboCell({
    super.key,
    required this.quantity,
    this.vehicleTrailerCombo = '',
    required this.jobTypeId,
    required this.onSave,
    this.width,
  });

  @override
  riverpod.ConsumerState<EditableVehicleComboCell> createState() =>
      _EditableVehicleComboCellState();
}

class _EditableVehicleComboCellState
    extends riverpod.ConsumerState<EditableVehicleComboCell> {
  bool _isEditing = false;
  VehicleTrailerCombo? _selectedCombo;

  @override
  void initState() {
    super.initState();
    _selectedCombo = VehicleTrailerCombo.tryParse(widget.vehicleTrailerCombo) ??
        VehicleTrailerCombo.fromLegacyQuantity(widget.quantity,
            jobTypeId: widget.jobTypeId);
    // Ensure the combo is valid for this job type
    final validCombos = VehicleTrailerCombo.forJobType(widget.jobTypeId);
    if (_selectedCombo != null && !validCombos.contains(_selectedCombo)) {
      _selectedCombo = null;
    }
    // If no valid combo found, default to first option
    if (_selectedCombo == null &&
        VehicleTrailerCombo.isVehicleJobType(widget.jobTypeId)) {
      _selectedCombo = validCombos.first;
    }
  }

  void _saveChanges() {
    if (_selectedCombo != null) {
      widget.onSave(_selectedCombo!.legacyQuantity(jobTypeId: widget.jobTypeId),
          _selectedCombo!.name);
    }
    setState(() {
      _isEditing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return riverpod.Consumer(
      builder: (context, ref, child) {
        final scaleProvider = ref.watch(scaleRiverpod);
        if (!VehicleTrailerCombo.isVehicleJobType(widget.jobTypeId)) {
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
              child: DropdownButtonFormField<VehicleTrailerCombo>(
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
                items: VehicleTrailerCombo.forJobType(widget.jobTypeId)
                    .map((combo) {
                  return DropdownMenuItem<VehicleTrailerCombo>(
                    value: combo,
                    child: Text(
                      combo.label,
                      style: TextStyle(
                          fontSize: scaleProvider.mediumFontSize,
                          fontWeight: FontWeight.bold),
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
                      _selectedCombo?.label ?? widget.quantity.toString(),
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
